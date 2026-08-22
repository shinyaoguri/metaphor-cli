#include "CMetaphorFrameIPC.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

int metaphor_shm_open_anon(void) {
    char name[32];
    for (int attempt = 0; attempt < 100; attempt++) {
        snprintf(name, sizeof name, "/metaphor-cli-%d-%d", (int)getpid(), attempt);
        int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd >= 0) {
            /* 名前は即座に捨てる。オブジェクトは fd で生き、最後の参照が消えれば回収される。 */
            shm_unlink(name);
            return fd;
        }
        if (errno != EEXIST) {
            return -1;
        }
    }
    return -1;
}

ssize_t metaphor_send_fd(int sock, int fd, const void *buf, size_t len) {
    struct iovec iov = { (void *)buf, len };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof control);

    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof control;

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(int));

    return sendmsg(sock, &msg, 0);
}

ssize_t metaphor_recv_fd(int sock, void *buf, size_t cap, int *out_fd) {
    if (out_fd) {
        *out_fd = -1;
    }
    struct iovec iov = { buf, cap };
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof control);

    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof control;

    ssize_t n = recvmsg(sock, &msg, 0);
    if (n <= 0) {
        return n;
    }
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg != NULL; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS &&
            cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
            int fd;
            memcpy(&fd, CMSG_DATA(cmsg), sizeof(int));
            if (out_fd) {
                *out_fd = fd;
            } else {
                close(fd);
            }
        }
    }
    return n;
}
