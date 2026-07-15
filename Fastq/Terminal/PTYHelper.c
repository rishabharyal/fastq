#include <util.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>

/// Child returns 0, parent returns pid (>0), failure returns -1.
pid_t fastq_forkpty(int *master_fd, int rows, int cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows > 0 ? (unsigned short)rows : 40;
    ws.ws_col = cols > 0 ? (unsigned short)cols : 120;
    return forkpty(master_fd, NULL, NULL, &ws);
}

int fastq_resize_pty(int master_fd, int rows, int cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}
