"""Real HTTP, SSDP and event-subscription checks against an isolated media folder."""
import http.client
import http.server
from pathlib import Path
import queue
import select
import socket
import subprocess
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
IP = subprocess.check_output(["/usr/sbin/ipconfig", "getifaddr", "en0"], text=True).strip()
events = queue.Queue()
callback_bytes = queue.Queue()


class Callback(http.server.BaseHTTPRequestHandler):
    def do_NOTIFY(self):
        events.put((self.headers, self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(200)
        if self.path == "/stream":
            self.send_header("Content-Length", str(32 * 1024 * 1024))
        self.end_headers()
        if self.path == "/stream":
            self.connection.settimeout(2)
            sent = 0
            try:
                for _ in range(512):
                    self.wfile.write(b"x" * 65536)
                    self.wfile.flush()
                    sent += 65536
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass
            finally:
                callback_bytes.put(sent)

    def log_message(self, *_):
        pass


def run():
    callback = http.server.HTTPServer((IP, 0), Callback)
    threading.Thread(target=callback.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="lantern-integration-") as folder:
        fixture = Path(folder)
        payload = bytes(range(256)) * 4096
        (fixture / "Episode & One.mp4").write_bytes(payload)
        subtitle = b"1\n00:00:00,000 --> 00:00:01,000\nHello from Lantern\n"
        (fixture / "Episode & One.srt").write_bytes(subtitle)
        (fixture / "private.txt").write_text("Not shared")
        (fixture / "Season").mkdir()
        (fixture / "Season" / "Two.mkv").write_bytes(b"second-video")
        port_socket = socket.socket()
        port_socket.bind((IP, 0))
        port = port_socket.getsockname()[1]
        port_socket.close()
        process = subprocess.Popen([str(ROOT / ".build/debug/lantern-serve"), folder, IP, str(port)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        try:
            deadline = time.monotonic() + 12
            ready = False
            while time.monotonic() < deadline:
                if select.select([process.stdout], [], [], 0.25)[0]:
                    line = process.stdout.readline()
                    if line.startswith("READY "):
                        ready = True
                        break
                    if not line or line.startswith("STOPPED "):
                        raise AssertionError("Server failed: " + line)
            assert ready, "Server failed to start within 12 seconds"

            def request(method, path, body=None, headers=None):
                connection = http.client.HTTPConnection(IP, port, timeout=5)
                connection.request(method, path, body, headers or {})
                response = connection.getresponse()
                result = response.status, dict(response.getheaders()), response.read()
                connection.close()
                return result

            status, _, body = request("GET", "/description.xml")
            assert status == 200 and ET.fromstring(body).tag.endswith("root")
            status, _, body = request("GET", "/content.xml")
            assert status == 200 and b"Browse" in body
            soap = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex><RequestedCount>0</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>'
            status, _, body = request("POST", "/control/content", soap, {"SOAPAction": '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"'})
            assert status == 200
            result = ET.fromstring(body).find(".//Result")
            didl = ET.fromstring(result.text)
            media = didl.find("{urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/}item")
            assert media is not None
            media_path = "/media/" + media.attrib["id"] + ".mp4"
            sub_path = "/subtitles/" + media.attrib["id"] + ".srt"
            assert len(didl) == 2
            assert media.find("{http://www.sec.co.kr/}CaptionInfoEx").text.endswith(sub_path)

            status, headers, body = request("GET", media_path)
            assert status == 200 and body == payload
            assert headers["CaptionInfo.sec"].endswith(sub_path)
            status, headers, body = request("HEAD", media_path)
            assert status == 200 and body == b"" and int(headers["Content-Length"]) == len(payload)
            for spec, expected in [("bytes=5-19", payload[5:20]), ("bytes=-9", payload[-9:]), ("bytes=1048570-", payload[1048570:])]:
                status, headers, body = request("GET", media_path, headers={"Range": spec})
                assert status == 206 and body == expected, spec
                assert "Content-Range" in headers
            assert request("GET", media_path, headers={"Range": "bytes=999999999-"})[0] == 416
            assert request("GET", sub_path)[2] == subtitle
            for path in ["/private.txt", "/media/../../etc/hosts", "/media/%2e%2e%2fprivate.txt", "/subtitles/missing.srt"]:
                assert request("GET", path)[0] == 404, path

            callback_url = f"<http://{IP}:{callback.server_port}/notify>"
            status, headers, _ = request("SUBSCRIBE", "/events/content", headers={"CALLBACK": callback_url, "NT": "upnp:event"})
            assert status == 200, status
            sid = headers["SID"]
            event_headers, notification = events.get(timeout=8)
            assert event_headers["SID"] == sid and b"SystemUpdateID" in notification
            assert request("SUBSCRIBE", "/events/content", headers={"SID": sid})[0] == 200
            assert request("UNSUBSCRIBE", "/events/content", headers={"SID": sid})[0] == 200
            assert request("SUBSCRIBE", "/events/content", headers={"CALLBACK": "<http://127.0.0.1:1/>", "NT": "upnp:event"})[0] == 412

            status, headers, _ = request("SUBSCRIBE", "/events/content", headers={"CALLBACK": f"<http://{IP}:{callback.server_port}/stream>", "NT": "upnp:event"})
            assert status == 200
            events.get(timeout=8)
            assert callback_bytes.get(timeout=5) < 2 * 1024 * 1024, "NOTIFY must close after response headers instead of buffering a device's body"
            assert request("UNSUBSCRIBE", "/events/content", headers={"SID": headers["SID"]})[0] == 200

            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp.bind((IP, 0))
            udp.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(IP))
            udp.settimeout(4)
            udp.sendto(b'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 1\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n', ("239.255.255.250", 1900))
            found = False
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                reply, _ = udp.recvfrom(8192)
                if f"LOCATION: http://{IP}:{port}/description.xml".encode() in reply:
                    found = True
                    break
            udp.close()
            assert found, "No multicast discovery reply from Lantern"

            bad_search = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            bad_search.bind((IP, 0))
            bad_search.settimeout(4)
            bad_search.sendto(b'M-SEARCH * HTTP/1.1\r\nMAN: "ssdp:discover"\r\nMX: nan\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n', (IP, 1900))
            assert b"200 OK" in bad_search.recvfrom(8192)[0]
            bad_search.close()

            # An indexed video must not become a route to an unindexed file, even inside the folder.
            (fixture / "Episode & One.mp4").unlink()
            (fixture / "Episode & One.mp4").symlink_to(fixture / "private.txt")
            assert request("GET", media_path)[0] == 404
            assert request("HEAD", media_path)[0] == 404

            # Replacing an already-indexed media file with an outside symlink must not expose it.
            (fixture / "Episode & One.mp4").unlink()
            (fixture / "Episode & One.mp4").symlink_to("/etc/hosts")
            assert request("GET", media_path)[0] == 404
            (fixture / "Episode & One.srt").unlink()
            (fixture / "Episode & One.srt").symlink_to("/etc/hosts")
            assert request("GET", sub_path)[0] == 404
            print("PASS: discovery, device/SCPD XML, folder browse, full/HEAD/range streaming, subtitles, event subscribe/renew/unsubscribe, callback restrictions, path and symlink isolation")
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            callback.shutdown()


if __name__ == "__main__":
    run()
