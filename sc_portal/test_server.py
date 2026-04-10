import socket

HOST = '10.0.0.1'
PORT = 80

html_content = """HTTP/1.1 200 OK
Content-Type: text/html; charset=UTF-8
Connection: close

<!DOCTYPE html>
<html>
<head><title>Test</title><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="font-size: 50px; text-align: center; margin-top: 20%;">
    <h1>SONO ENTRATO</h1>
    <p>Se leggi questo, PHP era il problema.</p>
</body>
</html>
"""

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind((HOST, PORT))
    s.listen()
    print(f"In ascolto su {HOST}:{PORT}...")
    while True:
        conn, addr = s.accept()
        with conn:
            print(f"Connesso a {addr}")
            request = conn.recv(1024)
            print(request.decode('utf-8', errors='ignore'))
            conn.sendall(html_content.encode('utf-8'))
