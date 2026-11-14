// ishplus-agent: runs in the Linux guest (static, any distribution).
//
// Finds the TCP ports programs listen on and reports them to iSH+ over the
// org.ishplus.ports virtio-serial port ("L <port> <port>...\n"), which then
// forwards them from the iPad's localhost through QEMU, like Docker or WSL.
// QEMU delivers forwarded connections to the guest's network address, so for
// programs that listen only on the guest's localhost (many development
// servers), the agent relays connections from that address to them.

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_PORTS 256
#define MAX_RELAYS 64
#define MAX_CONNECTIONS 256
#define BUFFER 65536

struct listener {
    int port;
    bool any;      // listens on all addresses (or the guest's address)
    bool loopback; // listens on 127.0.0.1 or ::1
    bool v6;       // the loopback listener is IPv6 only
};

struct relay {
    int port;
    int fd;
    bool v6; // connect to ::1 instead of 127.0.0.1
};

struct connection {
    int a, b;              // client, server
    bool a_done, b_done;   // that side has finished sending (half-closed)
};

static struct relay relays[MAX_RELAYS];
static int relay_count;
static struct connection connections[MAX_CONNECTIONS];
static int connection_count;
static struct in_addr guest_address;

static bool hex_is_zero(const char *hex, size_t len) {
    for (size_t i = 0; i < len; i++)
        if (hex[i] != '0')
            return false;
    return true;
}

static struct listener *find(struct listener *list, int count, int port) {
    for (int i = 0; i < count; i++)
        if (list[i].port == port)
            return &list[i];
    return NULL;
}

// Reads the listening sockets from /proc/net/tcp or tcp6.
static int scan(const char *path, bool v6, struct listener *list, int count) {
    FILE *f = fopen(path, "r");
    if (f == NULL)
        return count;
    char line[512];
    fgets(line, sizeof(line), f); // header
    while (fgets(line, sizeof(line), f) != NULL) {
        char local[64];
        unsigned port, state;
        if (sscanf(line, "%*d: %63[0-9A-Fa-f]:%x %*s %x", local, &port, &state) != 3 || state != 0x0A)
            continue;
        size_t len = strlen(local);
        bool any = hex_is_zero(local, len);
        bool loopback = false;
        // Loopback is 127.0.0.1 (or ::1) only: programs listening on other
        // 127.x addresses keep them to Linux (systemd-resolved's DNS stub
        // on 127.0.0.53 and .54), like any other specific address
        const unsigned localhost = 0x0100007f; // 127.0.0.1, as read below
        if (!v6 && len == 8) {
            unsigned address = strtoul(local, NULL, 16); // network order, read as host order
            loopback = address == localhost;
            if (address == guest_address.s_addr)
                any = true;
        } else if (v6 && len == 32) {
            loopback = strcmp(local, "00000000000000000000000001000000") == 0;
            // IPv4-mapped 127.x and the guest's address
            if (strncmp(local, "0000000000000000FFFF0000", 24) == 0) {
                unsigned address = strtoul(local + 24, NULL, 16);
                loopback = address == localhost;
                any = address == guest_address.s_addr;
            }
        }
        if (!any && !loopback)
            continue; // not reachable from iSH+
        struct listener *l = find(list, count, port);
        if (l == NULL) {
            if (count == MAX_PORTS)
                continue;
            l = &list[count++];
            *l = (struct listener) {.port = port};
        }
        l->any |= any;
        if (loopback) {
            if (!l->loopback)
                l->v6 = v6;
            l->loopback = true;
        }
    }
    fclose(f);
    return count;
}

static void find_guest_address(void) {
    // The address the guest's traffic leaves from (QEMU's network is 10.0.2.0/24)
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in gateway = {.sin_family = AF_INET, .sin_port = htons(9)};
    inet_pton(AF_INET, "10.0.2.2", &gateway.sin_addr);
    struct sockaddr_in self;
    socklen_t len = sizeof(self);
    if (fd >= 0 && connect(fd, (struct sockaddr *) &gateway, sizeof(gateway)) == 0 &&
        getsockname(fd, (struct sockaddr *) &self, &len) == 0)
        guest_address = self.sin_addr;
    if (fd >= 0)
        close(fd);
}

static int open_relay(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr = guest_address};
    if (bind(fd, (struct sockaddr *) &address, sizeof(address)) < 0 || listen(fd, 16) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void close_connection(int i) {
    close(connections[i].a);
    close(connections[i].b);
    connections[i] = connections[--connection_count];
}

static void accept_relayed(struct relay *r) {
    int client = accept4(r->fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (client < 0)
        return;
    int server = -1;
    if (r->v6) {
        struct sockaddr_in6 address = {.sin6_family = AF_INET6, .sin6_port = htons(r->port), .sin6_addr = IN6ADDR_LOOPBACK_INIT};
        server = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (server >= 0 && connect(server, (struct sockaddr *) &address, sizeof(address)) < 0) {
            close(server);
            server = -1;
        }
    } else {
        struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(r->port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        server = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (server >= 0 && connect(server, (struct sockaddr *) &address, sizeof(address)) < 0) {
            close(server);
            server = -1;
        }
    }
    if (server < 0 || connection_count == MAX_CONNECTIONS) {
        if (server >= 0)
            close(server);
        close(client);
        return;
    }
    fcntl(server, F_SETFL, fcntl(server, F_GETFL) | O_NONBLOCK);
    connections[connection_count++] = (struct connection) {.a = client, .b = server};
}

// Copies what is readable from one side to the other. Returns false on an
// error; sets *done when that side has finished sending (passed on to the
// other side, which may still answer).
static bool pump(int from, int to, bool *done) {
    static char buffer[BUFFER];
    ssize_t n = read(from, buffer, sizeof(buffer));
    if (n == 0) {
        *done = true;
        shutdown(to, SHUT_WR);
        return true;
    }
    if (n < 0)
        return errno == EAGAIN || errno == EINTR;
    for (ssize_t done = 0; done < n;) {
        ssize_t w = write(to, buffer + done, n - done);
        if (w < 0) {
            if (errno != EAGAIN && errno != EINTR)
                return false;
            struct pollfd p = {.fd = to, .events = POLLOUT};
            poll(&p, 1, 1000);
            continue;
        }
        done += w;
    }
    return true;
}

static char *find_port_device(const char *name) {
    static char path[64];
    DIR *dir = opendir("/sys/class/virtio-ports");
    if (dir == NULL)
        return NULL;
    struct dirent *entry;
    char *found = NULL;
    while ((entry = readdir(dir)) != NULL && found == NULL) {
        if (entry->d_name[0] == '.')
            continue;
        char file[300], value[128] = "";
        snprintf(file, sizeof(file), "/sys/class/virtio-ports/%s/name", entry->d_name);
        FILE *f = fopen(file, "r");
        if (f == NULL)
            continue;
        if (fgets(value, sizeof(value), f) != NULL) {
            value[strcspn(value, "\n")] = 0;
            if (strcmp(value, name) == 0) {
                snprintf(path, sizeof(path), "/dev/%s", entry->d_name);
                found = path;
            }
        }
        fclose(f);
    }
    closedir(dir);
    return found;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    int report = -1;
    char last[2048] = "";
    time_t last_sent = 0;
    for (;;) {
        if (guest_address.s_addr == 0)
            find_guest_address();
        if (report < 0) {
            char *device = find_port_device("org.ishplus.ports");
            if (device != NULL)
                report = open(device, O_WRONLY | O_CLOEXEC);
        }

        // What listens, and the relays it needs
        struct listener list[MAX_PORTS];
        int count = scan("/proc/net/tcp", false, list, 0);
        count = scan("/proc/net/tcp6", true, list, count);
        for (int i = 0; i < relay_count; i++) {
            struct listener *l = find(list, count, relays[i].port);
            if (l == NULL || !l->loopback) { // the program stopped (or listens everywhere now)
                close(relays[i].fd);
                relays[i--] = relays[--relay_count];
            }
        }
        if (guest_address.s_addr != 0) {
            for (int i = 0; i < count; i++) {
                struct listener *l = &list[i];
                bool relayed = false;
                for (int j = 0; j < relay_count; j++)
                    relayed |= relays[j].port == l->port;
                // A loopback-only listener (our relay makes it look like "any")
                if (l->loopback && !relayed && !l->any && relay_count < MAX_RELAYS) {
                    int fd = open_relay(l->port);
                    if (fd >= 0)
                        relays[relay_count++] = (struct relay) {l->port, fd, l->v6};
                }
            }
        }

        // Report the ports (again every 10 seconds, in case iSH+ reconnected)
        char message[2048] = "L";
        size_t used = 1;
        for (int i = 0; i < count && used < sizeof(message) - 8; i++)
            used += snprintf(message + used, sizeof(message) - used, " %d", list[i].port);
        strcat(message, "\n");
        if (report >= 0 && (strcmp(message, last) != 0 || time(NULL) - last_sent >= 10)) {
            if (write(report, message, strlen(message)) < 0 && errno != EAGAIN) {
                close(report);
                report = -1;
            } else {
                strcpy(last, message);
                last_sent = time(NULL);
            }
        }

        // Relay traffic until the next scan
        struct timespec start;
        clock_gettime(CLOCK_MONOTONIC, &start);
        for (;;) {
            struct pollfd fds[MAX_RELAYS + 2 * MAX_CONNECTIONS];
            int n = 0;
            for (int i = 0; i < relay_count; i++)
                fds[n++] = (struct pollfd) {.fd = relays[i].fd, .events = POLLIN};
            for (int i = 0; i < connection_count; i++) {
                // A side that finished sending is not polled (-1 is ignored)
                fds[n++] = (struct pollfd) {.fd = connections[i].a_done ? -1 : connections[i].a, .events = POLLIN};
                fds[n++] = (struct pollfd) {.fd = connections[i].b_done ? -1 : connections[i].b, .events = POLLIN};
            }
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long elapsed = (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000;
            if (elapsed >= 2000)
                break;
            if (poll(fds, n, 2000 - elapsed) <= 0)
                continue;
            int polled = connection_count; // accepting adds connections not polled yet
            int k = 0;
            for (int i = 0; i < relay_count; i++, k++)
                if (fds[k].revents & POLLIN)
                    accept_relayed(&relays[i]);
            int base = k;
            for (int i = polled - 1; i >= 0; i--) {
                struct pollfd *a = &fds[base + 2 * i], *b = &fds[base + 2 * i + 1];
                struct connection *c = &connections[i];
                bool ok = true;
                if (a->revents & (POLLIN | POLLHUP | POLLERR))
                    ok = pump(c->a, c->b, &c->a_done);
                if (ok && (b->revents & (POLLIN | POLLHUP | POLLERR)))
                    ok = pump(c->b, c->a, &c->b_done);
                if (!ok || (c->a_done && c->b_done))
                    close_connection(i);
            }
        }
    }
}
