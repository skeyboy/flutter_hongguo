"""Expose Android emulator host ports to devices on the same LAN.

Each mapping has the form LISTEN_PORT:TARGET_HOST:TARGET_PORT. The relay binds
to 0.0.0.0, so a phone or another computer can reach the emulator through the
development machine's LAN IP. Test-host tooling only; never part of the app.
"""
import argparse
import select
import socket
import threading


def _pump(client, target_host, target_port):
    try:
        upstream = socket.create_connection((target_host, target_port), timeout=5)
    except OSError:
        client.close()
        return
    pair = (client, upstream)
    try:
        while True:
            readable, _, _ = select.select(pair, [], [], 120)
            if not readable:
                break
            for sock in readable:
                peer = upstream if sock is client else client
                chunk = sock.recv(65536)
                if not chunk:
                    return
                peer.sendall(chunk)
    except OSError:
        pass
    finally:
        client.close()
        upstream.close()


def _serve(listen_port, target_host, target_port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", listen_port))
    server.listen(32)
    print(f'LAN relay 0.0.0.0:{listen_port} -> {target_host}:{target_port}', flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=_pump, args=(client, target_host, target_port), daemon=True).start()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mappings', nargs='+', help='LISTEN_PORT:TARGET_HOST:TARGET_PORT')
    args = parser.parse_args()
    for item in args.mappings:
        parts = item.split(':')
        if len(parts) != 3:
            raise SystemExit('Invalid mapping: ' + item)
        listen_port, target_host, target_port = int(parts[0]), parts[1], int(parts[2])
        threading.Thread(target=_serve, args=(listen_port, target_host, target_port), daemon=True).start()
    threading.Event().wait()


if __name__ == '__main__':
    main()
