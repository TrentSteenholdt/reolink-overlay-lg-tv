#!/usr/bin/python3
"""Decode doorbell video into private PNG frames for the floating QML tile."""

import ctypes
import json
import os
import re
import select
import signal
import struct
import time
import zlib


OVERLAY_DIR = "/var/lib/webosbrew/camera-overlay"
CONFIG = OVERLAY_DIR + "/stream.json"
PID_FILE = OVERLAY_DIR + "/producer.pid"
FRAME_FILE = "/tmp/camera-overlay-frame.png"
MODE_FILE = "/tmp/camera-overlay-mode"
TIMEOUT_FILE = "/tmp/camera-overlay-timeout-seconds"
NOTIFICATION_FILE = "/tmp/camera-overlay-notification.json"
WIDTH = 528
HEIGHT = 296
FRAME_BYTES = WIDTH * HEIGHT * 3
FRAME_INTERVAL_SECONDS = 0.18
running = True


def stop(_signal=None, _frame=None):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
os.environ["GST_DEBUG"] = "0"

with open(CONFIG, encoding="utf-8") as stream_file:
    config = json.load(stream_file)

try:
    with open(TIMEOUT_FILE, encoding="ascii") as timeout_file:
        timeout_seconds = int(timeout_file.read().strip())
except (OSError, ValueError):
    timeout_seconds = 0
deadline = time.monotonic() + timeout_seconds if timeout_seconds > 0 else float("inf")
last_notification_id = None


def refresh_deadline():
    global deadline, last_notification_id
    try:
        with open(NOTIFICATION_FILE, encoding="utf-8") as notification_file:
            payload = json.load(notification_file)
        notification_id = payload.get("id")
        if notification_id and notification_id != last_notification_id:
            duration = int(payload.get("durationSeconds", timeout_seconds))
            if 0 <= duration <= 86400:
                deadline = time.monotonic() + duration if duration > 0 else float("inf")
                last_notification_id = notification_id
    except (OSError, ValueError, TypeError):
        pass


if config.get("testClip") is True:
    source = (
        "filesrc location=/tmp/doorbell-media-probe.mp4 ! "
        "qtdemux ! h264parse ! avdec_h264"
    )
    credentials = None
else:
    host = config.get("host", "")
    username = config.get("username", "")
    password = config.get("password", "")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", host) or not username or not password:
        raise SystemExit("Invalid camera configuration")
    source = (
        "rtspsrc name=camera location=rtsp://"
        + host
        + ":554/h264Preview_01_sub protocols=tcp latency=100 ! "
        "application/x-rtp,media=video,encoding-name=H264 ! "
        "rtph264depay ! h264parse ! avdec_h264"
    )
    credentials = (username.encode(), password.encode())

read_fd, write_fd = os.pipe()
pipeline_spec = (
    source
    + " ! videoconvert ! videoscale ! "
    + f"video/x-raw,format=RGB,width={WIDTH},height={HEIGHT}"
    + f" ! fdsink fd={write_fd} sync=true"
)

gst = ctypes.CDLL("libgstreamer-1.0.so.0")
gobject = ctypes.CDLL("libgobject-2.0.so.0")
gst.gst_init.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
gst.gst_parse_launch.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
gst.gst_parse_launch.restype = ctypes.c_void_p
gst.gst_bin_get_by_name.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
gst.gst_bin_get_by_name.restype = ctypes.c_void_p
gst.gst_element_set_state.argtypes = [ctypes.c_void_p, ctypes.c_int]
gst.gst_element_get_bus.argtypes = [ctypes.c_void_p]
gst.gst_element_get_bus.restype = ctypes.c_void_p
gst.gst_bus_timed_pop_filtered.argtypes = [
    ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint
]
gst.gst_bus_timed_pop_filtered.restype = ctypes.c_void_p
gst.gst_object_unref.argtypes = [ctypes.c_void_p]
gst.gst_mini_object_unref.argtypes = [ctypes.c_void_p]


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def png_frame(rgb):
    row_bytes = WIDTH * 3
    rows = bytearray((row_bytes + 1) * HEIGHT)
    for row in range(HEIGHT):
        source_start = row * row_bytes
        dest_start = row * (row_bytes + 1) + 1
        rows[dest_start:dest_start + row_bytes] = rgb[source_start:source_start + row_bytes]
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(rows, 1))
        + png_chunk(b"IEND", b"")
    )


gst.gst_init(None, None)
error = ctypes.c_void_p()
pipeline = gst.gst_parse_launch(pipeline_spec.encode(), ctypes.byref(error))
if not pipeline or error.value:
    raise SystemExit("Video pipeline could not be created")
if credentials:
    camera = gst.gst_bin_get_by_name(pipeline, b"camera")
    if not camera:
        raise SystemExit("RTSP source missing")
    gobject.g_object_set(
        ctypes.c_void_p(camera),
        ctypes.c_char_p(b"user-id"),
        ctypes.c_char_p(credentials[0]),
        ctypes.c_char_p(b"user-pw"),
        ctypes.c_char_p(credentials[1]),
        ctypes.c_void_p(),
    )
    gst.gst_object_unref(camera)

bus = gst.gst_element_get_bus(pipeline)
pending = bytearray()
last_frame = 0.0
try:
    gst.gst_element_set_state(pipeline, 4)  # GST_STATE_PLAYING
    while running and time.monotonic() < deadline:
        refresh_deadline()
        ready, _, _ = select.select([read_fd], [], [], 0.2)
        if ready:
            chunk = os.read(read_fd, 65536)
            if not chunk:
                break
            pending.extend(chunk)
            while len(pending) >= FRAME_BYTES:
                rgb = bytes(pending[:FRAME_BYTES])
                del pending[:FRAME_BYTES]
                now = time.monotonic()
                if now - last_frame < FRAME_INTERVAL_SECONDS:
                    continue
                last_frame = now
                temp = FRAME_FILE + "." + str(os.getpid())
                with open(temp, "wb") as frame_file:
                    frame_file.write(png_frame(rgb))
                    os.fchmod(frame_file.fileno(), 0o600)
                os.replace(temp, FRAME_FILE)
        message = gst.gst_bus_timed_pop_filtered(bus, 0, 3)  # EOS | ERROR
        if message:
            gst.gst_mini_object_unref(message)
            break
finally:
    # Unblock fdsink before stopping GStreamer if its pipe filled while a PNG
    # was being encoded. Otherwise set_state(NULL) can wait forever.
    os.close(read_fd)
    gst.gst_element_set_state(pipeline, 1)  # GST_STATE_NULL
    gst.gst_object_unref(bus)
    gst.gst_object_unref(pipeline)
    os.close(write_fd)
    try:
        with open(PID_FILE, encoding="ascii") as pid_file:
            is_current = pid_file.read().strip() == str(os.getpid())
    except OSError:
        is_current = False
    if is_current:
        try:
            os.unlink(FRAME_FILE)
        except FileNotFoundError:
            pass
        while running and time.monotonic() < deadline:
            time.sleep(0.2)
        for path in (MODE_FILE, PID_FILE):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
