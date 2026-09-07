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

volume_mute() {
  ensure_target || { pause; return; }
  cyan "Ses kapatılıyor..."
  if adb -s "$TARGET" shell media volume --stream 3 --set 0 >/dev/null 2>&1; then
    green "Ses kapatıldı (mute)."
  else
    adb -s "$TARGET" shell input keyevent 164 >/dev/null 2>&1
    green "Mute tuşu gönderildi."
  fi
  pause
}

volume_max() {
  ensure_target || { pause; return; }
  cyan "Ses maksimuma alınıyor..."
  if adb -s "$TARGET" shell media volume --stream 3 --set 15 >/dev/null 2>&1; then
    green "Ses tam ses (15/15)."
  else
    local i
    for i in $(seq 1 30); do
      adb -s "$TARGET" shell input keyevent 24 >/dev/null 2>&1
    done
    green "Ses yükseltme tuşları gönderildi."
  fi
  pause
}

guess_audio_mime() {
  local f ext
  f=$(basename "$1" | tr '[:upper:]' '[:lower:]')
  ext="${f##*.}"
  case "$ext" in
    mp3) echo "audio/mpeg" ;;
    m4a|aac) echo "audio/mp4" ;;
    ogg|opus) echo "audio/ogg" ;;
    wav) echo "audio/wav" ;;
    flac) echo "audio/flac" ;;
    *) echo "audio/*" ;;
  esac
}

send_home_for_bg() {
  # Bazı oynatıcılar Home sonrası arka planda devam eder
  sleep 2
  adb -s "$TARGET" shell input keyevent 3 >/dev/null 2>&1
}

play_audio_bg() {
  ensure_target || { pause; return; }
  echo
  echo " 1) URL ile çal (mp3/stream http/https)"
  echo " 2) Termux'taki ses dosyasını gönder ve çal"
  echo " 0) İptal"
  read -r -p "Seçim: " mode

  local url mime remote name
  case "$mode" in
    1)
      read -r -p "Ses URL: " url
      url="${url//[[:space:]]/}"
      [[ -z "$url" ]] && { red "URL boş."; pause; return; }
      [[ "$url" != http://* && "$url" != https://* ]] && url="https://${url}"
      mime=$(guess_audio_mime "$url")
      cyan "Çalınıyor (arka plan denemesi): $url"
      adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" -t "$mime" >/dev/null 2>&1 \
        || adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1
      send_home_for_bg
      green "Başlatıldı. Home gönderildi (arka plan için)."
      yellow "Not: Bazı TV uygulamaları arka planda susturur; VLC/müzik uygulaması daha iyi çalışır."
      ;;
    2)
      read -r -p "Termux dosya yolu: " url
      [[ -z "$url" || ! -f "$url" ]] && { red "Dosya bulunamadı."; pause; return; }
      name=$(basename "$url")
      remote="/sdcard/tv-adb-audio"
      mime=$(guess_audio_mime "$name")
      cyan "Dosya TV'ye gönderiliyor..."
      adb -s "$TARGET" shell mkdir -p "$remote" >/dev/null 2>&1
      adb -s "$TARGET" push "$url" "${remote}/${name}" || { red "Push başarısız."; pause; return; }
      cyan "Oynatılıyor..."
      if adb -s "$TARGET" shell pm path org.videolan.vlc >/dev/null 2>&1; then
        adb -s "$TARGET" shell am start -a android.intent.action.VIEW \
          -d "file://${remote}/${name}" -t "$mime" org.videolan.vlc >/dev/null 2>&1
      else
        adb -s "$TARGET" shell am start -a android.intent.action.VIEW \
          -d "file://${remote}/${name}" -t "$mime" >/dev/null 2>&1
      fi
      send_home_for_bg
      green "Dosya çalınıyor (Home ile arka plan denendi): ${name}"
      ;;
    *) return ;;
  esac
  pause
}

stop_audio() {
  ensure_target || { pause; return; }
  cyan "Medya durduruluyor..."
  # Pause / stop keyevents
  adb -s "$TARGET" shell input keyevent 127 >/dev/null 2>&1  # PAUSE
  adb -s "$TARGET" shell input keyevent 86 >/dev/null 2>&1   # STOP
  # Yaygın oynatıcıları kapat
  for pkg in \
    org.videolan.vlc \
    com.google.android.youtube.tv \
    com.google.android.youtube \
    com.android.music \
    com.google.android.apps.youtube.music \
    com.spotify.tv.android \
    com.teamsmart.videomanager.tv
  do
    adb -s "$TARGET" shell am force-stop "$pkg" >/dev/null 2>&1
  done
  green "Durdurma komutları gönderildi."
  pause
}

send_key() {
  adb -s "$TARGET" shell input keyevent "$1" >/dev/null 2>&1
}

reverse_remote() {
  ensure_target || { pause; return; }
  clear 2>/dev/null || true
  cyan "======================================"
  cyan "   TERS KUMANDA MODU"
  cyan "======================================"
  yellow "Fiziksel kumanda değişmez; bu panelden kontrol ters!"
  echo
  echo "  W / ↑  →  TV'de AŞAĞI"
  echo "  S / ↓  →  TV'de YUKARI"
  echo "  A / ←  →  TV'de SAĞ"
  echo "  D / →  →  TV'de SOL"
  echo "  Enter / O / Boşluk  →  OK"
  echo "  B  →  Geri"
  echo "  H  →  Home"
  echo "  M  →  Mute"
  echo "  Q  →  Çıkış"
  echo
  green "Hazır. Tuşlara bas..."
  # Uyarı niyetine Home'a kısa bildirim denemesi (yok sayılabilir)
  adb -s "$TARGET" shell cmd notification post -t "Ters Kumanda" tvadb "Yukari artik asagi!" >/dev/null 2>&1 || true

  local key rest
  while true; do
    IFS= read -rsn1 key || break
    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 0.1 rest || rest=""
      case "$rest" in
        "[A") send_key 20; printf "↓ " ;;  # up arrow -> DOWN
        "[B") send_key 19; printf "↑ " ;;  # down -> UP
        "[C") send_key 21; printf "← " ;;  # right -> LEFT
        "[D") send_key 22; printf "→ " ;;  # left -> RIGHT
      esac
      continue
    fi
    case "$key" in
      w|W) send_key 20; printf "↓ " ;;          # DPAD_DOWN
      s|S) send_key 19; printf "↑ " ;;          # DPAD_UP
      a|A) send_key 22; printf "→ " ;;          # DPAD_RIGHT
      d|D) send_key 21; printf "← " ;;          # DPAD_LEFT
      o|O|" "|$'\n'|$'\r') send_key 23; printf "OK " ;; # DPAD_CENTER
      b|B) send_key 4; printf "Geri " ;;       # BACK
      h|H) send_key 3; printf "Home " ;;       # HOME
      m|M) send_key 164; printf "Mute " ;;     # VOLUME_MUTE
      q|Q)
        echo
        green "Ters kumanda kapatıldı."
        pause
        return
        ;;
    esac
  done
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
    echo "12) Ses: mute"
    echo "13) Ses: tam ses"
    echo "14) Arka planda ses çal"
    echo "15) Sesi / medyayı durdur"
    echo "16) Ters kumanda"
    echo "17) Yeniden başlat (reboot)"
    echo "18) TV'de TCP ADB açma ipuçları"
    echo "19) Bağlantıyı kes"
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
      12) volume_mute ;;
      13) volume_max ;;
      14) play_audio_bg ;;
      15) stop_audio ;;
      16) reverse_remote ;;
      17) reboot_device ;;
      18) enable_tcp_hint ;;
      19) disconnect_all ;;
      0) green "Görüşürüz."; exit 0 ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
    esac
  done
}

main_menu
