"""Run pure BLE scheduling regression checks without a radio or signing."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / 'App/Adapters/BLE/ESP32BLECentral.swift').read_text()
pure = source[:source.index('@MainActor\nfinal class ESP32BLECentral')]
pure = pure.replace('@preconcurrency import CoreBluetooth', '').replace('import MotoNavigationCore', '')
checks = r'''
let idle = BLEWriteProgressPolicy.action(pending: 0, inFlight: false, started: 0, progressed: 0, now: 86_400_000)
precondition(idle == .idle, "Idle without navigation must never disconnect")
precondition(BLEWriteProgressPolicy.action(pending: 3, inFlight: false, started: 0, progressed: 100, now: 2099) == .idle)
precondition(BLEWriteProgressPolicy.action(pending: 3, inFlight: false, started: 0, progressed: 100, now: 2100) == .retry)
precondition(BLEWriteProgressPolicy.action(pending: 0, inFlight: true, started: 100, progressed: 100, now: 8101) == .reconnect)
precondition(BLEWriteProgressPolicy.action(pending: 3, inFlight: true, started: 100, progressed: 0, now: 8100) == .idle, "Never duplicate an in-flight write")
precondition(BLEWriteProgressPolicy.action(pending: 3, inFlight: true, started: 100, progressed: 0, now: 50) == .idle, "Clock regression must not underflow")
precondition(BLEWritePumpPolicy.action(pendingFrameCount: 3, canSend: false, nowMs: 5000, lastSendMs: 100, pacingMs: 15) == .idle, "Recovery must respect backpressure")
precondition(BLEWritePumpPolicy.action(pendingFrameCount: 3, canSend: true, nowMs: 110, lastSendMs: 100, pacingMs: 15) == .wait(milliseconds: 5))
precondition(BLEWritePumpPolicy.action(pendingFrameCount: 3, canSend: true, nowMs: 115, lastSendMs: 100, pacingMs: 15) == .sendOne)
print("PASS 9 BLE transport scheduling checks")
'''
with tempfile.TemporaryDirectory() as directory:
    script = Path(directory) / 'BLETransportChecks.swift'
    script.write_text(pure + checks)
    subprocess.run(['swift', str(script)], check=True)
