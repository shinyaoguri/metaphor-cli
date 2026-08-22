#ifndef CMETAPHOR_FRAME_IPC_H
#define CMETAPHOR_FRAME_IPC_H

#include <sys/types.h>

/// live viewer の frame IPC（metaphor ⇄ metaphor-cli 契約点 5）のうち、Swift から
/// 直接呼べない POSIX API（`shm_open` と `sendmsg` / `recvmsg` の `CMSG_*` マクロ）を
/// 包む薄いシム。wire だけが契約で、このシムは metaphor 本体の `CMetaphorIPC` と
/// 同名・同形だが共有はしない（cli は本体に SwiftPM 依存しない）。

/// 匿名の POSIX 共有メモリを作り、その fd を返す（失敗は -1）。
/// 名前は作った直後に `shm_unlink` するので、オブジェクトは fd だけで生きる
/// （名前の衝突や後始末の漏れが無い）。viewer（親）側ではテストの fake producer だけが使う。
int metaphor_shm_open_anon(void);

/// `buf` の `len` バイトを送り、同じ `sendmsg` に `fd` を `SCM_RIGHTS` で添える。
/// 戻り値は `sendmsg` のもの（送ったバイト数。失敗は -1）。テストの fake producer 用。
ssize_t metaphor_send_fd(int sock, int fd, const void *buf, size_t len);

/// `recvmsg` で最大 `cap` バイトを `buf` へ読み、`SCM_RIGHTS` で fd が添えられていれば
/// `*out_fd` に入れる（無ければ -1）。戻り値は `recvmsg` のもの
/// （読んだバイト数。0 = EOF、失敗は -1 で `errno` を見る）。
ssize_t metaphor_recv_fd(int sock, void *buf, size_t cap, int *out_fd);

#endif
