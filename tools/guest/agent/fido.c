// ishplus-fido: runs in the Linux guest (static, any distribution).
//
// A virtual FIDO security key for programs in Linux (ssh with sk-* keys,
// through libfido2): a HID device made with /dev/uhid, so it appears as a
// normal security key (/dev/hidrawN). It speaks CTAPHID itself (channels,
// framing, PING, CANCEL, KEEPALIVE) and forwards each CTAP2 (CBOR) or U2F
// (MSG) request to iSH+ over the org.ishplus.fido virtio-serial port:
//     "X <command> <length>\n<payload>"   (command: 0x90 CBOR, 0x83 MSG)
//     "C\n"                               (cancel)
// iSH+ answers "<status> <length>\n<payload>" after talking to a key over
// NFC (status 0: the payload is the key's answer; otherwise a CTAP error).

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/uhid.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define REPORT 64
#define INIT_DATA (REPORT - 7)
#define CONT_DATA (REPORT - 5)
#define MAX_MESSAGE 7609 // the most CTAPHID can carry

enum {
    CMD_PING = 0x81, CMD_MSG = 0x83, CMD_INIT = 0x86, CMD_WINK = 0x88,
    CMD_CBOR = 0x90, CMD_CANCEL = 0x91, CMD_KEEPALIVE = 0xBB, CMD_ERROR = 0xBF,
};
enum { ERR_INVALID_CMD = 0x01, ERR_INVALID_LEN = 0x03, ERR_INVALID_SEQ = 0x04, ERR_CHANNEL_BUSY = 0x06, ERR_OTHER = 0x7F };
enum { CTAP2_ERR_KEEPALIVE_CANCEL = 0x2D, CTAP2_ERR_ACTION_TIMEOUT = 0x2F, CTAP1_ERR_OTHER = 0x7F };

// A FIDO HID device: usage page 0xF1D0, 64-byte input and output reports
static const uint8_t descriptor[] = {
    0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01,
    0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02,
    0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02,
    0xC0,
};

static int uhid = -1, port = -1;
static uint32_t next_channel = 1;

// The request being assembled from packets, or waiting for iSH+
static struct {
    bool active, forwarded;
    uint32_t channel;
    uint8_t command;
    uint16_t length, received;
    uint8_t seq;
    uint8_t data[MAX_MESSAGE];
} request;

static void send_report(const uint8_t report[REPORT]) {
    struct uhid_event ev = {.type = UHID_INPUT2};
    ev.u.input2.size = REPORT;
    memcpy(ev.u.input2.data, report, REPORT);
    if (write(uhid, &ev, sizeof(ev)) < 0)
        perror("uhid input");
}

// Sends a message to the host, split into packets
static void send_message(uint32_t channel, uint8_t command, const uint8_t *data, size_t length) {
    uint8_t report[REPORT] = {0};
    memcpy(report, &channel, 4);
    report[4] = command;
    report[5] = length >> 8;
    report[6] = length & 0xff;
    size_t n = length < INIT_DATA ? length : INIT_DATA;
    memcpy(report + 7, data, n);
    send_report(report);
    for (uint8_t seq = 0; n < length; seq++) {
        memset(report, 0, REPORT);
        memcpy(report, &channel, 4);
        report[4] = seq;
        size_t chunk = length - n < CONT_DATA ? length - n : CONT_DATA;
        memcpy(report + 5, data + n, chunk);
        n += chunk;
        send_report(report);
    }
}

static void send_error(uint32_t channel, uint8_t code) {
    send_message(channel, CMD_ERROR, &code, 1);
}

static bool write_all(int fd, const void *data, size_t length) {
    for (size_t done = 0; done < length;) {
        ssize_t n = write(fd, (const char *) data + done, length - done);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            return false;
        }
        done += n;
    }
    return true;
}

// Answers from iSH+, read as they come
static uint8_t answer_buffer[MAX_MESSAGE + 64];
static size_t answer_used;

static void forward(void) {
    char header[32];
    int n = snprintf(header, sizeof(header), "X %d %d\n", request.command, request.length);
    if (!write_all(port, header, n) || !write_all(port, request.data, request.length)) {
        send_error(request.channel, ERR_OTHER);
        request.active = false;
        return;
    }
    request.forwarded = true;
    answer_used = 0;
}

// A whole answer from iSH+ (status and payload) for the forwarded request
static void handle_answer(void) {
    char *newline = memchr(answer_buffer, '\n', answer_used);
    if (newline == NULL)
        return;
    int status = 0, length = 0;
    if (sscanf((char *) answer_buffer, "%d %d", &status, &length) != 2 || length < 0 || length > MAX_MESSAGE) {
        answer_used = 0;
        return;
    }
    size_t header = newline - (char *) answer_buffer + 1;
    if (answer_used < header + length)
        return; // not all here yet
    if (request.active && request.forwarded) {
        if (status == 0) {
            send_message(request.channel, request.command, answer_buffer + header, length);
        } else if (request.command == CMD_CBOR) {
            uint8_t code = status;
            send_message(request.channel, CMD_CBOR, &code, 1);
        } else {
            uint8_t sw[2] = {0x6F, 0x00}; // U2F: no precise diagnosis
            send_message(request.channel, CMD_MSG, sw, 2);
        }
        request.active = false;
    }
    memmove(answer_buffer, answer_buffer + header + length, answer_used - header - length);
    answer_used -= header + length;
}

// A packet the host (libfido2) sent
static void handle_report(const uint8_t *report) {
    uint32_t channel;
    memcpy(&channel, report, 4);
    if (report[4] & 0x80) { // initialization packet
        uint8_t command = report[4];
        uint16_t length = report[5] << 8 | report[6];
        if (command == CMD_CANCEL) {
            if (request.active && request.channel == channel) {
                if (request.forwarded)
                    write_all(port, "C\n", 2);
                uint8_t code = CTAP2_ERR_KEEPALIVE_CANCEL;
                send_message(channel, CMD_CBOR, &code, 1);
                request.active = false;
            }
            return;
        }
        if (request.active && request.channel != channel) {
            send_error(channel, ERR_CHANNEL_BUSY);
            return;
        }
        if (length > MAX_MESSAGE) {
            send_error(channel, ERR_INVALID_LEN);
            return;
        }
        request = (typeof(request)) {.active = true, .channel = channel, .command = command, .length = length};
        size_t n = length < INIT_DATA ? length : INIT_DATA;
        memcpy(request.data, report + 7, n);
        request.received = n;
    } else { // continuation
        if (!request.active || request.channel != channel || request.forwarded)
            return;
        if (report[4] != request.seq++) {
            send_error(channel, ERR_INVALID_SEQ);
            request.active = false;
            return;
        }
        size_t n = request.length - request.received;
        if (n > CONT_DATA)
            n = CONT_DATA;
        memcpy(request.data + request.received, report + 5, n);
        request.received += n;
    }
    if (request.received < request.length)
        return;

    // A whole request
    switch (request.command) {
    case CMD_INIT: {
        if (request.length != 8) {
            send_error(channel, ERR_INVALID_LEN);
            break;
        }
        uint8_t answer[17];
        memcpy(answer, request.data, 8); // the nonce
        uint32_t assigned = channel == 0xffffffff ? next_channel++ : channel;
        memcpy(answer + 8, &assigned, 4);
        answer[12] = 2;                  // CTAPHID protocol version
        answer[13] = 1; answer[14] = 0; answer[15] = 0; // device version
        answer[16] = 0x01 | 0x04;        // WINK, CBOR (and MSG)
        send_message(channel, CMD_INIT, answer, sizeof(answer));
        request.active = false;
        break;
    }
    case CMD_PING:
        send_message(channel, CMD_PING, request.data, request.length);
        request.active = false;
        break;
    case CMD_WINK:
        send_message(channel, CMD_WINK, NULL, 0);
        request.active = false;
        break;
    case CMD_CBOR:
    case CMD_MSG:
        forward();
        break;
    default:
        send_error(channel, ERR_INVALID_CMD);
        request.active = false;
    }
}

static char *find_port(const char *name) {
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
        if (fgets(value, sizeof(value), f) && (value[strcspn(value, "\n")] = 0, strcmp(value, name) == 0)) {
            snprintf(path, sizeof(path), "/dev/%s", entry->d_name);
            found = path;
        }
        fclose(f);
    }
    closedir(dir);
    return found;
}

// There is no udev: let every user open the security key
static void open_up_hidraw(void) {
    DIR *dir = opendir("/sys/class/hidraw");
    if (dir == NULL)
        return;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "hidraw", 6) != 0)
            continue;
        char file[300], line[256];
        snprintf(file, sizeof(file), "/sys/class/hidraw/%s/device/uevent", entry->d_name);
        FILE *f = fopen(file, "r");
        if (f == NULL)
            continue;
        bool ours = false;
        while (fgets(line, sizeof(line), f))
            ours |= strstr(line, "HID_NAME=iSH+ Security Key") != NULL;
        fclose(f);
        if (ours) {
            char dev[300];
            snprintf(dev, sizeof(dev), "/dev/%s", entry->d_name);
            chmod(dev, 0666);
        }
    }
    closedir(dir);
}

int main(void) {
    char *device = NULL;
    for (int i = 0; i < 120 && (device = find_port("org.ishplus.fido")) == NULL; i++)
        sleep(1);
    if (device == NULL)
        return 0; // an iSH+ without the FIDO bridge
    port = open(device, O_RDWR | O_CLOEXEC);
    uhid = open("/dev/uhid", O_RDWR | O_CLOEXEC);
    if (port < 0 || uhid < 0) {
        perror("ishplus-fido");
        return 1;
    }
    struct uhid_event create = {.type = UHID_CREATE2};
    strcpy((char *) create.u.create2.name, "iSH+ Security Key");
    create.u.create2.rd_size = sizeof(descriptor);
    memcpy(create.u.create2.rd_data, descriptor, sizeof(descriptor));
    create.u.create2.bus = 0x03; // USB
    create.u.create2.vendor = 0x1209;
    create.u.create2.product = 0x4943;
    if (!write_all(uhid, &create, sizeof(create))) {
        perror("uhid create");
        return 1;
    }
    sleep(1);
    open_up_hidraw();

    struct timespec last_keepalive = {0};
    for (;;) {
        struct pollfd fds[2] = {{.fd = uhid, .events = POLLIN}, {.fd = port, .events = POLLIN}};
        poll(fds, 2, 100);
        if (fds[0].revents & POLLIN) {
            struct uhid_event ev;
            if (read(uhid, &ev, sizeof(ev)) > 0 && ev.type == UHID_OUTPUT) {
                const uint8_t *data = ev.u.output.data;
                size_t size = ev.u.output.size;
                // Without report IDs, a leading 0 may be the report number
                if (size == REPORT + 1 && data[0] == 0) {
                    data++;
                    size--;
                }
                if (size >= REPORT)
                    handle_report(data);
            }
        }
        if (fds[1].revents & POLLIN) {
            ssize_t n = read(port, answer_buffer + answer_used, sizeof(answer_buffer) - answer_used);
            if (n > 0) {
                answer_used += n;
                handle_answer();
            }
        }
        // While iSH+ waits for the key: "still processing, waiting for the user"
        if (request.active && request.forwarded) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if ((now.tv_sec - last_keepalive.tv_sec) * 1000 + (now.tv_nsec - last_keepalive.tv_nsec) / 1000000 >= 100) {
                uint8_t status = 2; // UPNEEDED: tap the key
                send_message(request.channel, CMD_KEEPALIVE, &status, 1);
                last_keepalive = now;
            }
        }
    }
}
