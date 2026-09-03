#!/usr/bin/env python3
# socks5-proxy.py —— ssh ProxyCommand 桥接器
# 用途：本地直连线路劣化时，让 ssh/scp 走本地 Clash 等 SOCKS5 代理连远端。
# 用法（ssh config 或 -o）：
#   ProxyCommand python <SKILL_ROOT>/scripts/socks5-proxy.py 7897 %h %p
# 参数：<代理端口> <目标主机> <目标端口>（%h %p 由 ssh 自动替换）
# 2026-09-03 新增：配合 vps-download.ps1 在直连 TCP 不通时使用。
import socket
import struct
import sys
import threading


def main():
    if len(sys.argv) < 4:
        print('usage: socks5-proxy.py <proxy_port> <host> <port>', file=sys.stderr)
        sys.exit(2)
    proxy_port = int(sys.argv[1])
    target_host = sys.argv[2]
    target_port = int(sys.argv[3])

    # SOCKS5 握手（无认证）
    s = socket.create_connection(('127.0.0.1', proxy_port), timeout=15)
    try:
        s.sendall(b'\x05\x01\x00')
        rep = s.recv(2)
        if len(rep) < 2 or rep[1] != 0:
            print('SOCKS5 handshake failed', file=sys.stderr)
            sys.exit(1)
        host_bytes = target_host.encode()
        req = (b'\x05\x01\x00\x03' + bytes([len(host_bytes)]) + host_bytes
               + struct.pack('>H', target_port))
        s.sendall(req)
        resp = s.recv(10)
        if len(resp) < 2 or resp[1] != 0:
            print(f'SOCKS5 connect to {target_host}:{target_port} failed rep={resp[1] if len(resp) > 1 else "?"}',
                  file=sys.stderr)
            sys.exit(1)
    except Exception as e:  # noqa: BLE001
        print(f'socks5 setup error: {e}', file=sys.stderr)
        sys.exit(1)

    # 双向转发 stdin/stdout <-> socket
    def pipe(src, dst):
        try:
            while True:
                data = src.read(65536)
                if not data:
                    break
                dst.write(data)
                dst.flush()
        except Exception:
            pass
        finally:
            try:
                dst.close()
            except Exception:
                pass

    t1 = threading.Thread(target=pipe, args=(sys.stdin.buffer, s), daemon=True)
    t2 = threading.Thread(target=pipe, args=(s, sys.stdout.buffer), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


if __name__ == '__main__':
    main()
