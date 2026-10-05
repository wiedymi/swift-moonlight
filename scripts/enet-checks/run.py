#!/usr/bin/env python3
"""Compile exact old/new Swift transport sources, use an external C echo host,
and compare release builds. All build files are automatically removed.
No C source or module is added to the Swift package.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]

def declaration(source, name):
    match = re.search(r'public (?:protocol|enum|struct) ' + re.escape(name) + r'\b', source)
    if not match:
        raise RuntimeError('Missing declaration: ' + name)
    start = source.index('{', match.start())
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]

def command(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

class Proxy:
    def __init__(self, port, drop, delay, reorder):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(('127.0.0.1', 0))
        self.port = self.socket.getsockname()[1]
        self.server = ('127.0.0.1', port)
        self.client = None
        self.drop = drop
        self.delay = delay / 1000
        self.reorder = reorder
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.run)
        self.thread.start()

    def run(self):
        queue = []
        counters = [0, 0]
        while not self.stopped.is_set():
            ready, _, _ = select.select([self.socket], [], [], 0.001)
            if ready:
                data, address = self.socket.recvfrom(65535)
                direction = int(address == self.server)
                if not direction:
                    self.client = address
                target = self.client if direction else self.server
                counters[direction] += 1
                number = counters[direction]
                if target and (not self.drop or number % self.drop):
                    extra = self.delay if self.reorder and number % 7 == 0 else 0
                    queue.append((time.monotonic() + self.delay + extra, data, target))
            now = time.monotonic()
            future = []
            for deadline, data, target in queue:
                if deadline <= now:
                    self.socket.sendto(data, target)
                else:
                    future.append((deadline, data, target))
            queue = future

    def close(self):
        self.stopped.set()
        self.thread.join()
        self.socket.close()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', default='3ae6b69')
    parser.add_argument('--count', type=int, default=2000)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--fragment-count', type=int, default=500)
    parser.add_argument('--rate', type=int, default=0, help='Target application packets per second; zero means unlimited')
    parser.add_argument('--width', type=int, choices=range(1, 65), help='Override the number of application packets in flight')
    parser.add_argument('--swift-baseline', type=Path, help='Folder with saved ENet Swift source files for a third comparison')
    parser.add_argument('--enet-source', type=Path, default=ROOT / '.build/checkouts/swift-enet', help='SwiftENet package checkout used by the current transport')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--video-bitrate', type=int, default=0, help='Concurrent loopback UDP Mbps; 0 disables')
    parser.add_argument('--video-duration', type=int, default=3)
    parser.add_argument('--moonlight-host', action='store_true')
    parser.add_argument('--channels', type=int, choices=range(1, 49), default=48)
    parser.add_argument('--scenario', action='append', choices=['loopback', 'unreliable', 'encrypted', 'fragmented', 'loss-delay-reorder'])
    args = parser.parse_args()
    if not 0 <= args.video_bitrate <= 200 or not 1 <= args.video_duration <= 60:
        parser.error("Video rate or duration outside supported range")
    if not 1 <= args.count <= 200000 or not 1 <= args.fragment_count <= 200000 or not 1 <= args.repeats <= 10:
        parser.error('count/repeats outside supported bounds')
    if not 0 <= args.rate <= 10000:
        parser.error('rate outside supported bounds')
    def old(path):
        return subprocess.check_output(['git', 'show', args.reference + ':' + path], cwd=ROOT)
    results = []
    with tempfile.TemporaryDirectory(prefix='swift-enet-') as directory:
        temp = Path(directory)
        vendor = temp / 'ENet'
        paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', args.reference, 'Vendor/ENet'], cwd=ROOT).decode().splitlines()
        for path in paths:
            target = vendor / Path(path).relative_to('Vendor/ENet')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(old(path))
        objects = []
        for source in sorted(vendor.glob('*.c')):
            obj = temp / (source.stem + '.o')
            command(['clang', '-O3', '-I', str(vendor / 'include'), '-c', str(source), '-o', str(obj)])
            objects.append(str(obj))
        reference = temp / 'libCENet.a'
        command(['ar', 'rcs', str(reference), *objects])
        host = temp / 'host'
        command(['clang', '-O3', '-I', str(vendor / 'include'), str(ROOT / 'scripts/enet-checks/ReferenceHost.c'), str(reference), '-o', str(host)])
        host_reference = args.reference
        if args.moonlight_host:
            fork = temp / 'moonlight-enet'
            command(['git', 'init', '-q', str(fork)])
            host_reference = 'c7353c059373f8d3fc83d451f8f1a477be3dc94e'
            command(['git', '-C', str(fork), 'fetch', '-q', '--depth', '1', 'https://github.com/cgutman/enet.git', host_reference])
            command(['git', '-C', str(fork), 'checkout', '-q', 'FETCH_HEAD'])
            # Mirror the platform feature defines normally supplied by CMake.
            features = ['HAS_FCNTL', 'HAS_INET_PTON', 'HAS_INET_NTOP', 'HAS_MSGHDR_FLAGS',
                        'HAS_SOCKLEN_T', 'HAS_GETADDRINFO', 'HAS_GETNAMEINFO', 'HAS_POLL',
                        'HAS_IPV6_PKTINFO', 'HAS_IP_PKTINFO']
            defines = ['-D' + feature for feature in features]
            host_sources = [str(p) for p in fork.glob('*.c') if p.name not in ['win32.c', 'enet_dll.c']]
            command(['clang', '-O3', '-DMOONLIGHT_ENET', *defines, '-I', str(fork / 'include'),
                     str(ROOT / 'scripts/enet-checks/ReferenceHost.c'), *host_sources, '-o', str(host)])
        common = temp / 'Interfaces.swift'
        declarations = []
        for path, names in [
            ('Sources/SwiftMoonlight/Dependencies/Protocols.swift', ['ControlChannelTransport', 'ControlTransportMetricsReporting', 'TypedControlPacketTransport', 'LocalPortReporting', 'ClosableTransport']),
            ('Sources/SwiftMoonlight/Input/InputSender.swift', ['InputPacketTransport']),
            ('Sources/SwiftMoonlight/Protocol/Control/ControlMessages.swift', ['ControlChannelID']),
        ]:
            source = (ROOT / path).read_text()
            declarations += [declaration(source, name) for name in names]
        common.write_text('import Foundation\n' + '\n\n'.join(declarations))
        old_transport = temp / 'CENetControlTransport.swift'
        old_transport.write_bytes(old('Sources/SwiftMoonlight/Network/Control/ENetControlTransport.swift'))
        sources = [str(common), str(ROOT / 'scripts/enet-checks/Driver.swift'),
                   str(ROOT / 'Sources/SwiftMoonlight/Core/ControlTransportMetricsSnapshot.swift'),
                   str(ROOT / 'Sources/SwiftMoonlight/Core/Errors.swift'),
                   str(ROOT / 'Sources/SwiftMoonlight/Network/UDP/BoundUDPSocket.swift'),
                   str(ROOT / 'Sources/SwiftMoonlight/Network/UDP/UDPSocketAddressing.swift'),
                   str(ROOT / 'Sources/SwiftMoonlight/Protocol/Control/ControlPacketCrypto.swift')]
        enet_sources = sorted((args.enet_source / 'Sources/SwiftENet').glob('*.swift'))
        if not enet_sources:
            parser.error('SwiftENet source not found; run swift package resolve or pass --enet-source')
        command(['swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                 '-module-cache-path', str(temp / 'module-cache'), '-emit-library', '-static', '-emit-module',
                 '-module-name', 'SwiftENet', '-emit-module-path', str(temp / 'SwiftENet.swiftmodule'),
                 *map(str, enet_sources), '-o', str(temp / 'libSwiftENet.a')])
        executables = {}
        labels = ['CENet', 'Swift-before', 'Swift'] if args.swift_baseline else ['CENet', 'Swift']
        for label in labels:
            executable = temp / label
            if label == 'CENet':
                extra = [str(old_transport), '-I', str(vendor / 'include'), '-L', str(temp), '-lCENet']
            elif label == 'Swift-before':
                extra = [str(args.swift_baseline / name) for name in
                         ['ENetWire.swift', 'ENetPeer.swift', 'ENetDatagramSocket.swift', 'ENetControlTransport.swift']]
            else:
                extra = [str(ROOT / 'Sources/SwiftMoonlight/Network/Control/ENetControlTransport.swift'),
                         '-I', str(temp), '-L', str(temp), '-lSwiftENet']
            command(['swiftc', '-O', '-module-cache-path', str(temp / 'module-cache'), '-module-name', 'ENetCheck', '-swift-version', '6', '-strict-concurrency=complete', *sources, *extra, '-o', str(executable)])
            executables[label] = executable
        # Unreliable traffic is measured only without loss. Fault cases require
        # all reliable messages to arrive exactly once, with byte equality.
        scenarios = [('loopback', 32, True, False, 16, 0, 0, False),
                     ('unreliable', 32, False, False, 16, 0, 0, False),
                     ('encrypted', 256, True, True, 16, 0, 0, False),
                     ('fragmented', 8192, True, False, 4, 0, 0, False),
                     ('loss-delay-reorder', 32, True, False, 16, 20, 5, True)]
        if args.scenario:
            scenarios = [item for item in scenarios if item[0] in args.scenario]
        for repeat in range(args.repeats):
            for scenario, size, reliable, encrypted, width, drop, delay, reorder in scenarios:
                offset = repeat % len(labels)
                for label in labels[offset:] + labels[:offset]:
                    server = subprocess.Popen([str(host), str(args.channels)], stdout=subprocess.PIPE, text=True)
                    proxy = None
                    try:
                        port = int(server.stdout.readline())
                        if drop or delay:
                            proxy = Proxy(port, drop, delay, reorder)
                            port = proxy.port
                        count = min(args.count, 500) if drop else min(args.count, args.fragment_count) if size > 4096 else args.count
                        line = subprocess.check_output([str(executables[label]), str(port), str(count), str(size),
                                                        str(int(reliable)), str(int(encrypted)), str(args.width or width), label, str(args.rate), str(args.video_bitrate), str(args.video_duration)], timeout=120, text=True)
                        result = json.loads(line)
                        result.update(scenario=scenario, repeat=repeat, hostReference=host_reference, channels=args.channels,
                                      ratePerSecond=args.rate, width=args.width or width,
                                      videoBitrateMbps=args.video_bitrate, videoDurationSeconds=args.video_duration)
                        results.append(result)
                        print(json.dumps(result, sort_keys=True), flush=True)
                    finally:
                        if proxy:
                            proxy.close()
                        server.terminate(); server.wait(timeout=5); server.stdout.close()
    if args.output:
        production_sources = [ROOT / 'Sources/SwiftMoonlight/Network/Control/ENetControlTransport.swift', ROOT / 'Sources/SwiftMoonlight/Network/UDP/BoundUDPSocket.swift']
        hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in production_sources}
        hashes.update({'SwiftENet/' + p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in enet_sources})
        metadata = {
            'reference': subprocess.check_output(['git', 'rev-parse', args.reference], cwd=ROOT, text=True).strip(),
            'languageMode': 6,
            'strictConcurrency': 'complete',
            'compiler': subprocess.check_output(['swiftc', '--version'], text=True).strip(),
            'machine': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
            'memoryBytes': int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
            'macOS': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
            'sourceSHA256': hashes,
            'results': results,
        }
        if args.swift_baseline:
            metadata['beforeSourceSHA256'] = {name: hashlib.sha256((args.swift_baseline / name).read_bytes()).hexdigest() for name in ['ENetWire.swift', 'ENetPeer.swift', 'ENetDatagramSocket.swift', 'ENetControlTransport.swift']}
        args.output.write_text(json.dumps(metadata, indent=2) + '\n')

if __name__ == '__main__':
    main()
