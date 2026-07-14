#ifndef FastqTerminal_Bridging_Header_h
#define FastqTerminal_Bridging_Header_h

#include <sys/types.h>

pid_t fastq_forkpty(int *master_fd, int rows, int cols);
int fastq_resize_pty(int master_fd, int rows, int cols);

#endif
