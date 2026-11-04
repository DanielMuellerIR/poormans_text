#ifndef PMT_PROCESS_H
#define PMT_PROCESS_H
int pmt_process_pidfd_open_owned(int pid, int ancestor);
int pmt_process_pidfd_ready(int fd, int timeout_ms);
int pmt_process_write_control(int fd, unsigned char value);
int pmt_process_open_directory(const char *path);
int pmt_process_open_relative_directory(int root_fd, const char *relative);
int pmt_process_unlink_owned_capture(int directory, const char *name, int descriptor);
#endif
