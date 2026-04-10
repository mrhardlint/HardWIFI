import socket
import sys

def scan_port(ip, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1.0)
    try:
        result = s.connect_ex((ip, port))
        if result == 0:
            return "OPEN"
        elif result == 111:
            return "REFUSED"
        else:
            return f"CLOSED ({result})"
    except Exception as e:
        return f"ERROR: {str(e)}"
    finally:
        s.close()

target = "10.20.174.40"
ports = [21, 22, 23, 53, 80, 443, 1900, 3128, 5000, 5555, 8000, 8080, 8443, 9000]

print(f"--- Deep Scan on {target} ---")
for p in ports:
    res = scan_port(target, p)
    if res == "OPEN":
        print(f"[!] Porta {p} e' APERTA!")
    # else:
    #    print(f"Porta {p}: {res}")
print("\nScansione completata.")
