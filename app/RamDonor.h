//
//  RamDonor.h
//  iSH+
//
//  Linux's RAM from memory donors: iSH+'s helper extension, started as
//  separate processes, allocates the memory, and iSH+ maps it. It does not
//  count toward iSH+'s own memory limit, which iOS ends iSH+ for.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Gets `bytes` of memory for Linux's RAM from donors, before QEMU starts;
/// returns how much the donors covered (the rest is iSH+'s own memory).
uint64_t ISHRamDonorPrepare(uint64_t bytes);

/// Makes QEMU (its library's dlopen handle) use that memory for Linux's main
/// RAM. Without it, or if QEMU lacks the hook, QEMU allocates RAM as before.
void ISHRamDonorInstall(void *qemuHandle);

/// What happened, for the log and Settings: e.g. "1024 MB from 2 donors".
NSString *_Nullable ISHRamDonorStatus(void);

NS_ASSUME_NONNULL_END
