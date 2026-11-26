#ifndef STELLA_DRIVE_H
#define STELLA_DRIVE_H
#include <stdint.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

// authopen -stdoutpipe returns one open file description using SCM_RIGHTS.
static inline int stella_receive_fd(int socket_fd) {
    char byte;
    struct iovec io = { &byte, sizeof(byte) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    struct msghdr msg = {0};
    msg.msg_iov = &io;
    msg.msg_iovlen = 1;
    msg.msg_control = control.bytes;
    msg.msg_controllen = sizeof(control.bytes);
    if (recvmsg(socket_fd, &msg, 0) <= 0 || (msg.msg_flags & MSG_CTRUNC)) return -1;
    struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
    if (!header || header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS ||
        header->cmsg_len != CMSG_LEN(sizeof(int))) return -1;
    int fd;
    memcpy(&fd, CMSG_DATA(header), sizeof(fd));
    return fd;
}

static inline int64_t stella_disk_size(int fd) {
    uint32_t size = 0;
    uint64_t count = 0;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, &size) || size != 512 ||
        ioctl(fd, DKIOCGETBLOCKCOUNT, &count) || count > INT64_MAX / size) return -1;
    return (int64_t)(size * count);
}
#endif
