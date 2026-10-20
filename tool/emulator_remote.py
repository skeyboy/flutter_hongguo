"""Emulator controller keyboard path, including virtio input devices.

For test hosts only. grpcio/grpcio-tools are optional dependencies and are never
part of the Flutter application. Emulator credentials stay in memory.
"""
from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

class EmulatorRemote:
    def __init__(self, serial):
        import grpc
        sdk = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk')))
        generated = ROOT / 'build/verification/tv-grpc'
        generated.mkdir(parents=True, exist_ok=True)
        proto = sdk / 'emulator/lib/emulator_controller.proto'
        if not (generated / 'emulator_controller_pb2.py').exists():
            subprocess.run([sys.executable, '-m', 'grpc_tools.protoc', '-I', str(proto.parent),
                            '--python_out=' + str(generated), '--grpc_python_out=' + str(generated), str(proto)], check=True)
        sys.path.insert(0, str(generated))
        import emulator_controller_pb2 as pb
        import emulator_controller_pb2_grpc as rpc
        self.pb = pb
        port = serial.removeprefix('emulator-')
        running = Path.home() / 'Library/Caches/TemporaryItems/avd/running'
        settings = None
        for path in running.glob('pid_*.ini'):
            values = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
            if values.get('port.serial') == port:
                settings = values
                break
        if settings is None:
            raise RuntimeError('No local emulator endpoint matches ' + serial)
        self.channel = grpc.insecure_channel('127.0.0.1:' + settings['grpc.port'])
        self.client = rpc.EmulatorControllerStub(self.channel)
        self.metadata = [('authorization', 'Bearer ' + settings['grpc.token'])]

    def press(self, android_code):
        # qwerty.kl: 232 is DPAD_CENTER; Android keycodes are not evdev codes.
        codes = {19: 103, 20: 108, 21: 105, 22: 106, 23: 232, 4: 158}
        event = self.pb.KeyboardEvent(codeType=self.pb.KeyboardEvent.Evdev,
                                     keyCode=codes[android_code],
                                     eventType=self.pb.KeyboardEvent.keypress)
        self.client.sendKey(event, metadata=self.metadata, timeout=10)
