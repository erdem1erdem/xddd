#!/data/data/com.termux/files/usr/bin/bash
# Termux → TV Box ADB menü betiği
# Kullanım: bash termux-tv-adb.sh

set -u
CONFIG_DIR="${HOME}/.config/tv-adb"
CONFIG_FILE="${CONFIG_DIR}/last_device"
DEFAULT_PORT=5555

mkdir -p "$CONFIG_DIR"

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[1;36m%s\033[0m\n' "$*"; }

pause() {
  echo
  read -r -p "Devam için Enter..." _
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_deps() {
  cyan "Eksik paketler kontrol ediliyor..."
  local pkgs=()
  need_cmd adb  || pkgs+=(android-tools)
  need_cmd nmap || pkgs+=(nmap)
  need_cmd nc   || pkgs+=(netcat-openbsd)
  need_cmd ip   || pkgs+=(iproute2)

  if ((${#pkgs[@]})); then
    yellow "Kurulacak: ${pkgs[*]}"
    pkg update -y
    pkg install -y "${pkgs[@]}"
  else
    green "Gerekli paketler hazır."
  fi
  pause
}

get_subnet() {
  # Örn: 192.168.1.0/24
  local route gw iface myip
  route=$(ip route show default 2>/dev/null | head -n1) || true
  gw=$(awk '{print $3}' <<<"$route")
  iface=$(awk '{print $5}' <<<"$route")
  myip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -n1 | cut -d/ -f1)

  if [[ -n "${myip:-}" ]]; then
    echo "${myip%.*}.0/24"
  elif [[ -n "${gw:-}" ]]; then
    echo "${gw%.*}.0/24"
  else
    echo "192.168.1.0/24"
  fi
}

save_target() {
  echo "$1" >"$CONFIG_FILE"
}

load_target() {
  if [[ -f "$CONFIG_FILE" ]]; then
    cat "$CONFIG_FILE"
  fi
}

current_target() {
  local t
  t=$(load_target)
  if [[ -n "${t:-}" ]]; then
    echo "$t"
  else
    echo "(kayıtlı yok)"
  fi
}

ensure_target() {
  local t
  t=$(load_target)
  if [[ -z "${t:-}" ]]; then
    red "Önce bir cihaza bağlan (menü 2 veya 3)."
    return 1
  fi
  TARGET="$t"
  return 0
}

scan_adb() {
  local subnet port
  subnet=$(get_subnet)
  port=${1:-$DEFAULT_PORT}

  cyan "Ağ: $subnet  |  Port: $port"
  yellow "Taranıyor..."

  local results=()
  if need_cmd nmap; then
    mapfile -t results < <(nmap -p "$port" --open -n "$subnet" 2>/dev/null \
      | awk '/Nmap scan report/{ip=$NF} /'"$port"'\/tcp open/{print ip}')
  else
    local base i
    base=$(cut -d. -f1-3 <<<"${subnet%%/*}")
    for i in $(seq 1 254); do
      if nc -z -w 1 "${base}.$i" "$port" 2>/dev/null; then
        results+=("${base}.$i")
        echo "  bulundu: ${base}.$i"
      fi
    done
  fi

  if ((${#results[@]} == 0)); then
    red "ADB portu açık cihaz bulunamadı."
    yellow "TV'de wireless ADB / tcpip 5555 açık mı?"
    pause
    return 1
  fi

  echo
  green "Bulunan cihazlar:"
  local i=1
  for ip in "${results[@]}"; do
    printf "  %d) %s:%s\n" "$i" "$ip" "$port"
    ((i++))
  done
  echo "  0) İptal"
  echo
  read -r -p "Seçim: " choice

  if [[ "$choice" == "0" || -z "$choice" ]]; then
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#results[@]})); then
    red "Geçersiz seçim."
    pause
    return 1
  fi

  local selected="${results[$((choice-1))]}:${port}"
  connect_to "$selected"
}

connect_to() {
  local target="$1"
  cyan "Bağlanılıyor: $target"
  adb disconnect >/dev/null 2>&1 || true
  if adb connect "$target" | tee /tmp/tv-adb-connect.txt | grep -qi "connected"; then
    save_target "$target"
    green "Bağlandı ve kaydedildi: $target"
    adb -s "$target" devices
  else
    red "Bağlantı başarısız."
    yellow "TV'de 'USB debugging izin ver' onayını kontrol et."
    cat /tmp/tv-adb-connect.txt 2>/dev/null || true
  fi
  pause
}

manual_connect() {
  local ip port
  read -r -p "TV IP adresi: " ip
  read -r -p "Port [${DEFAULT_PORT}]: " port
  port=${port:-$DEFAULT_PORT}
  [[ -z "$ip" ]] && { red "IP boş olamaz."; pause; return; }
  connect_to "${ip}:${port}"
}

show_info() {
  ensure_target || { pause; return; }
  cyan "Cihaz bilgisi: $TARGET"
  adb -s "$TARGET" shell '
    echo "Model : $(getprop ro.product.model)"
    echo "Marka : $(getprop ro.product.manufacturer)"
    echo "Android: $(getprop ro.build.version.release)"
    echo "SDK   : $(getprop ro.build.version.sdk)"
    echo "Root? : $(su -c id 2>/dev/null | head -n1 || echo yok/erişilemedi)"
    echo "--- IP ---"
    ip -4 addr show 2>/dev/null | awk "/inet /{print \$2, \$NF}" || ifconfig 2>/dev/null
  ' 2>/dev/null || red "Bilgi alınamadı (bağlantı koptu olabilir)."
  pause
}

open_shell() {
  ensure_target || { pause; return; }
  green "Shell açılıyor (çıkmak için: exit)"
  adb -s "$TARGET" shell
}

open_root_shell() {
  ensure_target || { pause; return; }
  green "Root shell deneniyor..."
  adb -s "$TARGET" shell su -c 'id; hostname; sh -'
}

run_custom() {
  ensure_target || { pause; return; }
  read -r -p "Shell komutu (örn: pm list packages): " cmd
  [[ -z "$cmd" ]] && return
  adb -s "$TARGET" shell "$cmd"
  pause
}

run_root_custom() {
  ensure_target || { pause; return; }
  read -r -p "Root komutu: " cmd
  [[ -z "$cmd" ]] && return
  adb -s "$TARGET" shell su -c "$cmd"
  pause
}

install_apk() {
  ensure_target || { pause; return; }
  read -r -p "APK yolu (Termux içi): " apk
  [[ -z "$apk" || ! -f "$apk" ]] && { red "Dosya bulunamadı."; pause; return; }
  adb -s "$TARGET" install -r "$apk"
  pause
}

push_file() {
  ensure_target || { pause; return; }
  local src dst
  read -r -p "Kaynak dosya: " src
  read -r -p "Hedef [/sdcard/]: " dst
  dst=${dst:-/sdcard/}
  [[ -z "$src" || ! -f "$src" ]] && { red "Dosya yok."; pause; return; }
  adb -s "$TARGET" push "$src" "$dst"
  pause
}

play_youtube() {
  ensure_target || { pause; return; }
  local url vid
  echo
  read -r -p "YouTube linki (veya video ID): " url
  url="${url//[[:space:]]/}"
  [[ -z "$url" ]] && { red "Link boş olamaz."; pause; return; }

  # Sadece video ID verildiyse linke çevir
  if [[ "$url" =~ ^[A-Za-z0-9_-]{11}$ ]]; then
    url="https://www.youtube.com/watch?v=${url}"
  elif [[ "$url" != http://* && "$url" != https://* ]]; then
    url="https://${url}"
  fi

  # youtu.be / watch?v= / shorts / embed içinden ID çıkar (mümkünse)
  vid=""
  if [[ "$url" =~ youtu\.be/([A-Za-z0-9_-]{11}) ]]; then
    vid="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ [\?\&]v=([A-Za-z0-9_-]{11}) ]]; then
    vid="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ /(shorts|embed|live)/([A-Za-z0-9_-]{11}) ]]; then
    vid="${BASH_REMATCH[2]}"
  fi
  if [[ -n "$vid" ]]; then
    url="https://www.youtube.com/watch?v=${vid}"
  fi

  cyan "TV'de açılıyor: $url"

  # Önce YouTube TV / YouTube / SmartTube, yoksa genel VIEW
  if adb -s "$TARGET" shell pm path com.google.android.youtube.tv >/dev/null 2>&1; then
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" com.google.android.youtube.tv >/dev/null
  elif adb -s "$TARGET" shell pm path com.google.android.youtube >/dev/null 2>&1; then
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" com.google.android.youtube >/dev/null
  elif adb -s "$TARGET" shell pm path com.teamsmart.videomanager.tv >/dev/null 2>&1; then
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" com.teamsmart.videomanager.tv >/dev/null
  else
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" >/dev/null
  fi

  if [[ $? -eq 0 ]]; then
    green "Oynatma komutu gönderildi."
  else
    red "Açılamadı. YouTube uygulaması kurulu mu?"
  fi
  pause
}

reboot_device() {
  ensure_target || { pause; return; }
  read -r -p "TV yeniden başlatılsın mı? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return
  adb -s "$TARGET" reboot
  yellow "Reboot gönderildi."
  pause
}

enable_tcp_hint() {
  cat <<'EOF'

TV box'ta ADB TCP açmak (TV'de root shell varsa):
  su
  setprop service.adb.tcp.port 5555
  stop adbd
  start adbd

USB ile bir kez bağlıysan (PC/Termux USB):
  adb tcpip 5555
  adb connect IP:5555

EOF
  pause
}

disconnect_all() {
  adb disconnect
  rm -f "$CONFIG_FILE"
  green "Bağlantılar kesildi, kayıt silindi."
  pause
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    cyan "======================================"
    cyan "   Termux → TV Box ADB Menü"
    cyan "======================================"
    echo " Kayıtlı hedef: $(current_target)"
    echo " Algılanan ağ : $(get_subnet)"
    echo
    echo " 1) Bağımlılıkları kur / kontrol et"
    echo " 2) Ağı tara ve ADB cihazı seç"
    echo " 3) IP girerek bağlan"
    echo " 4) Cihaz bilgisini göster"
    echo " 5) Normal shell"
    echo " 6) Root shell"
    echo " 7) Özel komut çalıştır"
    echo " 8) Root ile özel komut"
    echo " 9) APK yükle"
    echo "10) Dosya gönder (push)"
    echo "11) YouTube linki oynat"
    echo "12) Yeniden başlat (reboot)"
    echo "13) TV'de TCP ADB açma ipuçları"
    echo "14) Bağlantıyı kes"
    echo " 0) Çıkış"
    echo
    read -r -p "Seçim: " sel
    case "$sel" in
      1) install_deps ;;
      2) scan_adb "$DEFAULT_PORT" ;;
      3) manual_connect ;;
      4) show_info ;;
      5) open_shell ;;
      6) open_root_shell ;;
      7) run_custom ;;
      8) run_root_custom ;;
      9) install_apk ;;
      10) push_file ;;
      11) play_youtube ;;
      12) reboot_device ;;
      13) enable_tcp_hint ;;
      14) disconnect_all ;;
      0) green "Görüşürüz."; exit 0 ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
    esac
  done
}

main_menu
