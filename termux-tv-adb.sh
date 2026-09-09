
#!/data/data/com.termux/files/usr/bin/bash
# Termux → TV Box ADB menü betiği
# Kullanım: bash termux-tv-adb.sh

set -u
CONFIG_DIR="${HOME}/.config/tv-adb"
CONFIG_FILE="${CONFIG_DIR}/last_device"
PC_CONFIG="${CONFIG_DIR}/last_pc"
PC_MAC_CONFIG="${CONFIG_DIR}/last_pc_mac"
PC_USER_CONFIG="${CONFIG_DIR}/last_pc_user"
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
  need_cmd ssh  || pkgs+=(openssh)
  need_cmd ping || pkgs+=(inetutils)
  need_cmd smbclient || pkgs+=(samba)

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

normalize_url() {
  local url="$1"
  url="${url//[[:space:]]/}"
  [[ -z "$url" ]] && { echo ""; return; }
  if [[ "$url" != http://* && "$url" != https://* && "$url" != file://* && "$url" != intent:* ]]; then
    url="https://${url}"
  fi
  echo "$url"
}

open_url() {
  ensure_target || { pause; return; }
  local url pkg
  echo
  read -r -p "Açılacak URL: " url
  url=$(normalize_url "$url")
  [[ -z "$url" ]] && { red "URL boş olamaz."; pause; return; }

  read -r -p "Paket (boş=otomatik seçim): " pkg
  cyan "TV'de açılıyor: $url"

  if [[ -n "${pkg:-}" ]]; then
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" "$pkg" >/dev/null 2>&1
  elif adb -s "$TARGET" shell pm path com.android.chrome >/dev/null 2>&1; then
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" com.android.chrome >/dev/null 2>&1
  elif adb -s "$TARGET" shell pm path com.android.browser >/dev/null 2>&1; then
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" com.android.browser >/dev/null 2>&1
  else
    adb -s "$TARGET" shell am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1
  fi

  if [[ $? -eq 0 ]]; then
    green "URL açma komutu gönderildi."
  else
    red "Açılamadı. Tarayıcı / uygun uygulama kurulu mu?"
  fi
  pause
}

show_proxy() {
  ensure_target || { pause; return; }
  local cur
  cur=$(adb -s "$TARGET" shell settings get global http_proxy 2>/dev/null | tr -d '\r')
  cyan "Mevcut http_proxy: ${cur:-"(yok / null)"}"
  pause
}

set_proxy() {
  ensure_target || { pause; return; }
  local host port value
  echo
  yellow "Not: Global HTTP proxy; HTTPS uygulamaları bazen yok sayar."
  yellow "ADB Wi-Fi üzerindenyse yanlış proxy bağlantıyı bozabilir."
  read -r -p "Proxy host (IP veya domain): " host
  read -r -p "Port [8080]: " port
  port=${port:-8080}
  host="${host//[[:space:]]/}"
  [[ -z "$host" ]] && { red "Host boş olamaz."; pause; return; }
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    red "Port sayı olmalı."
    pause
    return
  fi
  value="${host}:${port}"
  cyan "Proxy ayarlanıyor: $value"
  if adb -s "$TARGET" shell settings put global http_proxy "$value" >/dev/null 2>&1; then
    green "http_proxy = $value"
  else
    red "Ayarlanamadı."
  fi
  pause
}

clear_proxy() {
  ensure_target || { pause; return; }
  cyan "Proxy temizleniyor..."
  if adb -s "$TARGET" shell settings put global http_proxy :0 >/dev/null 2>&1 \
    || adb -s "$TARGET" shell settings delete global http_proxy >/dev/null 2>&1; then
    green "Proxy kapatıldı (:0 / silindi)."
  else
    red "Temizlenemedi."
  fi
  pause
}

hosts_redirect() {
  ensure_target || { pause; return; }
  local domain ip
  echo
  yellow "Root gerekir. /system/etc/hosts değiştirilir (yedek alınır)."
  yellow "Sadece kendi test cihazında kullan."
  read -r -p "Yönlenecek domain (örn: ornek.com): " domain
  read -r -p "Hedef IP: " ip
  domain="${domain//[[:space:]]/}"
  ip="${ip//[[:space:]]/}"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  [[ -z "$domain" || -z "$ip" ]] && { red "Domain ve IP gerekli."; pause; return; }

  cyan "hosts güncelleniyor: $domain -> $ip"
  adb -s "$TARGET" shell su -c "
set -e
HOSTS=/system/etc/hosts
remount_rw() {
  mount -o rw,remount /system 2>/dev/null || true
  mount -o rw,remount / 2>/dev/null || true
}
remount_rw
if [ ! -f \"\${HOSTS}.tvadb.bak\" ]; then
  cp \"\$HOSTS\" \"\${HOSTS}.tvadb.bak\" || true
fi
grep -v \"[[:space:]]${domain}\$\" \"\$HOSTS\" > /data/local/tmp/hosts.tvadb 2>/dev/null || cp \"\$HOSTS\" /data/local/tmp/hosts.tvadb
echo \"${ip} ${domain}\" >> /data/local/tmp/hosts.tvadb
cp /data/local/tmp/hosts.tvadb \"\$HOSTS\"
echo OK
" > /tmp/tvadb-hosts-out.txt 2>&1
  local rc=$?
  cat /tmp/tvadb-hosts-out.txt 2>/dev/null || true
  if [[ $rc -eq 0 ]] && grep -q OK /tmp/tvadb-hosts-out.txt 2>/dev/null; then
    green "Yönlendirme yazıldı. DNS önbelleği için uygulamayı yeniden aç."
  else
    red "Başarısız (root / remount?)."
  fi
  pause
}

hosts_restore() {
  ensure_target || { pause; return; }
  yellow "hosts yedeği geri yüklenecek."
  read -r -p "Onaylıyor musun? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return

  adb -s "$TARGET" shell su -c '
set -e
HOSTS=/system/etc/hosts
BAK=${HOSTS}.tvadb.bak
remount_rw() {
  mount -o rw,remount /system 2>/dev/null || true
  mount -o rw,remount / 2>/dev/null || true
}
remount_rw
[ -f "$BAK" ] || { echo NO_BAK; exit 2; }
cp "$BAK" "$HOSTS"
rm -f "$BAK"
echo OK
' > /tmp/tvadb-hosts-restore.txt 2>&1
  local rc=$?
  cat /tmp/tvadb-hosts-restore.txt 2>/dev/null || true
  if [[ $rc -eq 0 ]] && grep -q OK /tmp/tvadb-hosts-restore.txt 2>/dev/null; then
    green "hosts geri yüklendi."
  else
    red "Yedek yok veya geri yükleme başarısız."
  fi
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

# Fiziksel kumanda yönlerini keylayout üzerinden tersler (root + reboot gerekir)
reverse_remote_apply() {
  ensure_target || { pause; return; }
  yellow "Bu işlem TV'deki keylayout dosyalarını değiştirir (root)."
  yellow "Yedek alınır; geri almak için menüden KAPAT kullan."
  read -r -p "Ters kumandayı AÇmak için reboot dahil onaylıyor musun? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return

  cyan "Keylayout tersleniyor..."
  # shellcheck disable=SC2016
  adb -s "$TARGET" shell su -c '
set -e
remount_rw() {
  mount -o rw,remount /system 2>/dev/null || true
  mount -o rw,remount /vendor 2>/dev/null || true
  mount -o rw,remount / 2>/dev/null || true
}
swap_dirs() {
  # DPAD_UP <-> DOWN, LEFT <-> RIGHT (geçici token ile)
  sed -e "s/DPAD_UP/__TVADB_UP__/g" \
      -e "s/DPAD_DOWN/DPAD_UP/g" \
      -e "s/__TVADB_UP__/DPAD_DOWN/g" \
      -e "s/DPAD_LEFT/__TVADB_LEFT__/g" \
      -e "s/DPAD_RIGHT/DPAD_LEFT/g" \
      -e "s/__TVADB_LEFT__/DPAD_RIGHT/g"
}
remount_rw
count=0
for dir in /system/usr/keylayout /vendor/usr/keylayout /system_ext/usr/keylayout /product/usr/keylayout; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.kl; do
    [ -f "$f" ] || continue
    grep -qE "DPAD_(UP|DOWN|LEFT|RIGHT)" "$f" || continue
    # Zaten bizim yedeğimiz varsa tekrar bozma
    if [ -f "${f}.tvadb.bak" ]; then
      echo "SKIP (zaten yedekli): $f"
      continue
    fi
    cp "$f" "${f}.tvadb.bak" || continue
    swap_dirs < "${f}.tvadb.bak" > "${f}.tvadb.tmp"
    mv "${f}.tvadb.tmp" "$f"
    echo "OK: $f"
    count=$((count+1))
  done
done
echo "CHANGED=$count"
if [ "$count" -eq 0 ]; then
  echo "NO_FILES"
  exit 2
fi
' > /tmp/tvadb-reverse-out.txt 2>&1
  local rc=$?
  cat /tmp/tvadb-reverse-out.txt 2>/dev/null || true

  if grep -q "NO_FILES" /tmp/tvadb-reverse-out.txt 2>/dev/null; then
    red "Uygun keylayout bulunamadı veya yazılamadı."
    yellow "Root / system remount mümkün olmayabilir."
    pause
    return
  fi
  if [[ $rc -ne 0 ]] && ! grep -q "CHANGED=[1-9]" /tmp/tvadb-reverse-out.txt 2>/dev/null; then
    red "İşlem başarısız (root/remount?)."
    pause
    return
  fi

  green "Ters mapping yazıldı. Kumandanın ters olması için reboot şart."
  read -r -p "Şimdi reboot? [e/H]: " r
  if [[ "$r" =~ ^[eEyY]$ ]]; then
    adb -s "$TARGET" reboot
    yellow "Reboot gönderildi. Açılınca yönler ters olmalı."
  else
    yellow "Reboot etmeden çoğu kutuda etki etmez."
  fi
  pause
}

reverse_remote_restore() {
  ensure_target || { pause; return; }
  yellow "Yedekten keylayout geri yüklenecek."
  read -r -p "Ters kumandayı KAPATmak için reboot dahil onay? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return

  cyan "Yedekler geri yükleniyor..."
  adb -s "$TARGET" shell su -c '
set -e
remount_rw() {
  mount -o rw,remount /system 2>/dev/null || true
  mount -o rw,remount /vendor 2>/dev/null || true
  mount -o rw,remount / 2>/dev/null || true
}
remount_rw
count=0
for dir in /system/usr/keylayout /vendor/usr/keylayout /system_ext/usr/keylayout /product/usr/keylayout; do
  [ -d "$dir" ] || continue
  for bak in "$dir"/*.kl.tvadb.bak; do
    [ -f "$bak" ] || continue
    f="${bak%.tvadb.bak}"
    cp "$bak" "$f"
    rm -f "$bak"
    echo "RESTORED: $f"
    count=$((count+1))
  done
done
echo "RESTORED=$count"
[ "$count" -gt 0 ] || exit 2
' > /tmp/tvadb-restore-out.txt 2>&1
  local rc=$?
  cat /tmp/tvadb-restore-out.txt 2>/dev/null || true

  if [[ $rc -ne 0 ]]; then
    red "Geri yükleme başarısız veya yedek yok."
    pause
    return
  fi

  green "Orijinal keylayout geri yüklendi."
  read -r -p "Şimdi reboot? [e/H]: " r
  if [[ "$r" =~ ^[eEyY]$ ]]; then
    adb -s "$TARGET" reboot
    yellow "Reboot gönderildi. Yönler normale dönmeli."
  fi
  pause
}

prank_home_rain() {
  ensure_target || return 1
  cyan "Home yagmuru basliyor..."
  local i
  for i in $(seq 1 15); do
    adb -s "$TARGET" shell input keyevent 3 >/dev/null 2>&1
    sleep 0.12
  done
  green "Bitti. Ana ekran islandi."
}

prank_cat_walk() {
  ensure_target || return 1
  cyan "Bir kedi kumandaya oturdu..."
  local keys=(19 20 21 22 23 4 3)
  local i idx
  for i in $(seq 1 45); do
    idx=$((RANDOM % ${#keys[@]}))
    adb -s "$TARGET" shell input keyevent "${keys[$idx]}" >/dev/null 2>&1
    sleep 0.07
  done
  green "Kedi indirdi. Sanirim."
}

prank_app_roulette() {
  ensure_target || return 1
  cyan "Uygulama carki donuyor..."
  local pkgs=() pkg
  mapfile -t pkgs < <(adb -s "$TARGET" shell pm list packages -3 2>/dev/null \
    | sed 's/\r//g; s/^package://' \
    | grep -vE '^(com\.android\.shell|com\.android\.systemui)$' || true)
  if ((${#pkgs[@]} < 1)); then
    mapfile -t pkgs < <(adb -s "$TARGET" shell pm list packages 2>/dev/null \
      | sed 's/\r//g; s/^package://' \
      | grep -vE '^(android|com\.android\.(shell|systemui|providers\.)|com\.google\.android\.(gms|gsf|gsf\.login))' || true)
  fi
  if ((${#pkgs[@]} < 1)); then
    red "Acilacak uygulama bulunamadi."
    return 1
  fi
  pkg="${pkgs[$((RANDOM % ${#pkgs[@]}))]}"
  yellow "Secilen paket: $pkg"
  if ! adb -s "$TARGET" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
    adb -s "$TARGET" shell monkey -p "$pkg" 1 >/dev/null 2>&1 || true
  fi
  green "Rulet bitti. Bol sans."
}

prank_disco_volume() {
  ensure_target || return 1
  cyan "Disco ses modu (8 sn)..."
  local i
  for i in $(seq 1 16); do
    if ((i % 2 == 0)); then
      adb -s "$TARGET" shell media volume --stream 3 --set 0 >/dev/null 2>&1 \
        || adb -s "$TARGET" shell input keyevent 164 >/dev/null 2>&1
    else
      adb -s "$TARGET" shell media volume --stream 3 --set 15 >/dev/null 2>&1 \
        || adb -s "$TARGET" shell input keyevent 24 >/dev/null 2>&1
    fi
    sleep 0.45
  done
  green "DJ kabini kapandi."
}

prank_movie_sabotage() {
  ensure_target || return 1
  cyan "Film sabotaji basladi..."
  local i ev
  local events=(85 85 87 88 89 90 86)
  for i in $(seq 1 12); do
    ev=${events[$((RANDOM % ${#events[@]}))]}
    adb -s "$TARGET" shell input keyevent "$ev" >/dev/null 2>&1
    sleep 0.35
  done
  green "Izleyen kisiyi tebrik ederiz."
}

prank_fake_notify() {
  ensure_target || return 1
  local titles=(
    "Guvenlik Uyarisi"
    "Sistem"
    "Kumanda Mahkemesi"
    "Komsu Raporu"
    "Gizli Servis"
  )
  local bodies=(
    "Birisi seni izlerken izliyor."
    "Kumanda ifadeye cagrildi."
    "Bu TV cok fazla dizi izledi."
    "Test basarisiz: fazla ciddiye alindi."
    "Kedi tekrar baglandi."
    "Wi-Fi sizi muhbir olarak isaretledi."
  )
  local t b
  t="${titles[$((RANDOM % ${#titles[@]}))]}"
  b="${bodies[$((RANDOM % ${#bodies[@]}))]}"
  cyan "Sahte bildirim: $t"
  adb -s "$TARGET" shell cmd notification post -t "$t" tvprank "$b" >/dev/null 2>&1 \
    || adb -s "$TARGET" shell "am start -a android.intent.action.MAIN -e message '$b'" >/dev/null 2>&1 \
    || yellow "Bildirim API yok; metin yine de secildi."
  green "Gonderildi (destekleyen kutularda gorunur)."
}

prank_anim_chaos() {
  ensure_target || return 1
  echo
  echo " 1) Cok yavas UI (salyangoz)"
  echo " 2) Cok hizli UI (kahve sonrasi)"
  echo " 3) Normaline dondur"
  read -r -p "Seçim: " m
  local val=1
  case "$m" in
    1) val=5; cyan "Salyangoz modu..." ;;
    2) val=0.2; cyan "Hizli UI..." ;;
    3) val=1; cyan "Normal..." ;;
    *) return ;;
  esac
  adb -s "$TARGET" shell settings put global window_animation_scale "$val" >/dev/null 2>&1
  adb -s "$TARGET" shell settings put global transition_animation_scale "$val" >/dev/null 2>&1
  adb -s "$TARGET" shell settings put global animator_duration_scale "$val" >/dev/null 2>&1
  green "Animasyon ayari uygulandi (reboot yok)."
}

prank_brightness_flash() {
  ensure_target || return 1
  cyan "Parlaklik sokagi..."
  local old
  old=$(adb -s "$TARGET" shell settings get system screen_brightness 2>/dev/null | tr -d '\r')
  [[ "$old" =~ ^[0-9]+$ ]] || old=100
  adb -s "$TARGET" shell settings put system screen_brightness 1 >/dev/null 2>&1
  sleep 1.5
  adb -s "$TARGET" shell settings put system screen_brightness "$old" >/dev/null 2>&1
  green "Isiklar geri geldi."
}

prank_back_rain() {
  ensure_target || return 1
  cyan "Geri tus yagmuru..."
  local i
  for i in $(seq 1 12); do
    adb -s "$TARGET" shell input keyevent 4 >/dev/null 2>&1
    sleep 0.12
  done
  green "Neredeyiz? Kimse bilmiyor."
}

prank_settings_trap() {
  ensure_target || return 1
  cyan "Ayarlar tuzagi..."
  adb -s "$TARGET" shell am start -a android.settings.SETTINGS >/dev/null 2>&1 \
    || adb -s "$TARGET" shell am start -n com.android.tv.settings/.MainSettings >/dev/null 2>&1 \
    || adb -s "$TARGET" shell monkey -p com.android.tv.settings 1 >/dev/null 2>&1
  sleep 0.8
  adb -s "$TARGET" shell input keyevent 20 >/dev/null 2>&1
  adb -s "$TARGET" shell input keyevent 20 >/dev/null 2>&1
  green "Haydi ayarlardan ciksinlar."
}

prank_surprise() {
  ensure_target || return 1
  cyan "Surpriz paket hazirlaniyor..."
  local pick=$((RANDOM % 5))
  case "$pick" in
    0) prank_home_rain; sleep 0.3; prank_disco_volume ;;
    1) prank_cat_walk; sleep 0.3; prank_fake_notify ;;
    2) prank_movie_sabotage; sleep 0.3; prank_back_rain ;;
    3) prank_app_roulette; sleep 0.3; prank_brightness_flash ;;
    4) prank_disco_volume; sleep 0.3; prank_settings_trap ;;
  esac
  green "Surpriz tamam. Tesekkurler, kurban."
}

prank_menu() {
  ensure_target || { pause; return; }
  while true; do
    clear 2>/dev/null || true
    cyan "======================================"
    cyan "   SAKA / TEST EGLENCE MENUSU"
    cyan "======================================"
    echo " Hedef: $(current_target)"
    echo
    echo " 1) Home yagmuru"
    echo " 2) Kedi yurudu"
    echo " 3) Rastgele uygulama ruleti"
    echo " 4) Disco ses"
    echo " 5) Film sabotaji"
    echo " 6) Sahte bildirim"
    echo " 7) Animasyon cilginligi"
    echo " 8) Parlaklik sokagi"
    echo " 9) Geri tus yagmuru"
    echo "10) Ayarlar tuzagi"
    echo "11) SURPRIZ PAKET (rastgele kombo)"
    echo "12) Wi-Fi KAPAT"
    echo "13) Wi-Fi AC"
    echo " 0) Ana menuye don"
    echo
    read -r -p "Seçim: " p
    case "$p" in
      1) prank_home_rain; pause ;;
      2) prank_cat_walk; pause ;;
      3) prank_app_roulette; pause ;;
      4) prank_disco_volume; pause ;;
      5) prank_movie_sabotage; pause ;;
      6) prank_fake_notify; pause ;;
      7) prank_anim_chaos; pause ;;
      8) prank_brightness_flash; pause ;;
      9) prank_back_rain; pause ;;
      10) prank_settings_trap; pause ;;
      11) prank_surprise; pause ;;
      12) wifi_disable; pause ;;
      13) wifi_enable; pause ;;
      0) return ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
    esac
  done
}

wifi_disable() {
  ensure_target || return 1
  yellow "DIKKAT: ADB Wi-Fi uzerinden bagliysa baglanti KOPAR."
  read -r -p "Wi-Fi kapatilsin mi? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return
  cyan "Wi-Fi kapatiliyor..."
  if adb -s "$TARGET" shell svc wifi disable >/dev/null 2>&1; then
    green "Wi-Fi kapatma komutu gonderildi."
  elif adb -s "$TARGET" shell cmd wifi set-wifi-enabled disabled >/dev/null 2>&1; then
    green "Wi-Fi kapatildi (cmd wifi)."
  elif adb -s "$TARGET" shell su -c 'svc wifi disable' >/dev/null 2>&1; then
    green "Wi-Fi kapatildi (root)."
  else
    red "Kapatilamadi. Cihaz bu komutu engelliyor olabilir."
  fi
}

wifi_enable() {
  ensure_target || return 1
  cyan "Wi-Fi aciliyor..."
  if adb -s "$TARGET" shell svc wifi enable >/dev/null 2>&1; then
    green "Wi-Fi acma komutu gonderildi."
  elif adb -s "$TARGET" shell cmd wifi set-wifi-enabled enabled >/dev/null 2>&1; then
    green "Wi-Fi acildi (cmd wifi)."
  elif adb -s "$TARGET" shell su -c 'svc wifi enable' >/dev/null 2>&1; then
    green "Wi-Fi acildi (root)."
  else
    red "Acilamadi. USB ADB veya TV uzerinden elle acman gerekebilir."
  fi
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

save_pc() {
  echo "$1" >"$PC_CONFIG"
}

load_pc() {
  [[ -f "$PC_CONFIG" ]] && cat "$PC_CONFIG"
}

save_pc_mac() {
  echo "$1" >"$PC_MAC_CONFIG"
}

load_pc_mac() {
  [[ -f "$PC_MAC_CONFIG" ]] && cat "$PC_MAC_CONFIG"
}

save_pc_user() {
  echo "$1" >"$PC_USER_CONFIG"
}

load_pc_user() {
  if [[ -f "$PC_USER_CONFIG" ]]; then
    cat "$PC_USER_CONFIG"
  else
    echo "Administrator"
  fi
}

current_pc() {
  local ip mac
  ip=$(load_pc)
  mac=$(load_pc_mac)
  if [[ -n "${ip:-}" ]]; then
    if [[ -n "${mac:-}" ]]; then
      echo "${ip} (MAC: ${mac})"
    else
      echo "$ip"
    fi
  else
    echo "(kayıtlı yok)"
  fi
}

ensure_pc() {
  PC_IP=$(load_pc)
  if [[ -z "${PC_IP:-}" ]]; then
    red "Önce PC IP kaydet (PC menüsü → 1)."
    return 1
  fi
  PC_MAC=$(load_pc_mac)
  PC_USER=$(load_pc_user)
  return 0
}

pc_set_target() {
  local ip mac user
  read -r -p "PC IP adresi: " ip
  ip="${ip//[[:space:]]/}"
  [[ -z "$ip" ]] && { red "IP boş olamaz."; pause; return; }
  read -r -p "MAC (Wake-on-LAN, boş bırakılabilir): " mac
  mac="${mac//[[:space:]]/}"
  read -r -p "SSH kullanıcı [Administrator]: " user
  user=${user:-Administrator}
  save_pc "$ip"
  [[ -n "$mac" ]] && save_pc_mac "$mac" || rm -f "$PC_MAC_CONFIG"
  save_pc_user "$user"
  green "PC kaydedildi: $ip"
  pause
}

pc_ping() {
  ensure_pc || { pause; return; }
  cyan "Ping: $PC_IP"
  if ping -c 4 -W 2 "$PC_IP" 2>/dev/null; then
    green "PC yanıt veriyor."
  else
    yellow "Ping yok (kapalı, firewall veya ICMP kapalı olabilir)."
  fi
  pause
}

pc_probe_port() {
  local ip="$1" port="$2" label="$3"
  if nc -z -w 2 "$ip" "$port" 2>/dev/null; then
    green "  [AÇIK]  $label ($port)"
    return 0
  fi
  echo "  [kapalı] $label ($port)"
  return 1
}

pc_scan_services() {
  ensure_pc || { pause; return; }
  cyan "Servis taraması: $PC_IP"
  echo
  pc_probe_port "$PC_IP" 22   "SSH"
  pc_probe_port "$PC_IP" 445  "SMB (dosya paylaşımı)"
  pc_probe_port "$PC_IP" 3389 "RDP (uzaktan masaüstü)"
  pc_probe_port "$PC_IP" 5985 "WinRM (PowerShell uzaktan)"
  pc_probe_port "$PC_IP" 80   "HTTP"
  pc_probe_port "$PC_IP" 135  "RPC (Windows)"
  echo
  yellow "Açık port = o yöntemle uzaktan işlem yapılabilir."
  pause
}

pc_scan_network() {
  local subnet ip
  subnet=$(get_subnet)
  cyan "Ağdaki PC adayları taranıyor: $subnet"
  yellow "SSH(22), RDP(3389), SMB(445) açık olanlar listelenir..."
  echo

  if need_cmd nmap; then
    nmap -p 22,445,3389,5985 --open -n "$subnet" 2>/dev/null \
      | awk '/Nmap scan report/{ip=$NF} /\/tcp open/{print ip, $0}' \
      | sed 's/()//g'
  else
    local base i
    base=$(cut -d. -f1-3 <<<"${subnet%%/*}")
    for i in $(seq 1 254); do
      ip="${base}.$i"
      for port in 22 445 3389; do
        if nc -z -w 1 "$ip" "$port" 2>/dev/null; then
          echo "  $ip:$port açık"
        fi
      done
    done
  fi
  echo
  read -r -p "Kaydetmek için IP (boş=atla): " ip
  ip="${ip//[[:space:]]/}"
  [[ -n "$ip" ]] && { save_pc "$ip"; green "Kaydedildi: $ip"; }
  pause
}

pc_wol_send() {
  local mac="$1"
  local mac_clean
  mac_clean=$(echo "$mac" | tr -d ':-' | tr '[:upper:]' '[:lower:]')
  if [[ ${#mac_clean} -ne 12 ]]; then
    red "Geçersiz MAC."
    return 1
  fi

  if need_cmd wakeonlan; then
    wakeonlan "$mac" && return 0
  fi

  if need_cmd python; then
    python - <<PY
import socket
mac = "${mac_clean}"
data = b"\\xff" * 6 + bytes.fromhex(mac) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.sendto(data, ("255.255.255.255", 9))
PY
    return $?
  fi

  red "wakeonlan veya python gerekli (pkg install wakeonlan)."
  return 1
}

pc_wake() {
  ensure_pc || { pause; return; }
  if [[ -z "${PC_MAC:-}" ]]; then
    read -r -p "MAC adresi: " PC_MAC
    PC_MAC="${PC_MAC//[[:space:]]/}"
    [[ -z "$PC_MAC" ]] && { red "MAC gerekli."; pause; return; }
    save_pc_mac "$PC_MAC"
  fi
  cyan "Wake-on-LAN gönderiliyor: $PC_MAC -> $PC_IP"
  if pc_wol_send "$PC_MAC"; then
    green "Magic packet gönderildi. PC birkaç saniye içinde açılabilir."
    yellow "Not: BIOS'ta WOL + ağ kartında WOL açık olmalı."
  else
    red "Gönderilemedi. netcat/wakeonlan kontrol et."
  fi
  pause
}

pc_ssh_target() {
  echo "${PC_USER}@${PC_IP}"
}

pc_ssh_available() {
  ensure_pc || return 1
  nc -z -w 2 "$PC_IP" 22 2>/dev/null
}

pc_run_ssh() {
  local cmd="$1"
  ensure_pc || return 1
  if ! pc_ssh_available; then
    red "SSH (22) kapalı veya erişilemiyor."
    yellow "PC menüsü → 12 ile Windows'ta OpenSSH açma ipuçlarına bak."
    return 1
  fi
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$(pc_ssh_target)" "$cmd"
}

pc_shell() {
  ensure_pc || { pause; return; }
  if ! pc_ssh_available; then
    red "SSH kapalı."
    pause
    return
  fi
  green "SSH shell (çıkış: exit)"
  ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$(pc_ssh_target)"
}

pc_run_cmd() {
  ensure_pc || { pause; return; }
  local cmd
  read -r -p "Çalıştırılacak komut: " cmd
  [[ -z "$cmd" ]] && return
  pc_run_ssh "$cmd"
  pause
}

pc_open_url() {
  ensure_pc || { pause; return; }
  local url
  read -r -p "Açılacak URL: " url
  url=$(normalize_url "$url")
  [[ -z "$url" ]] && { red "URL boş."; pause; return; }
  cyan "PC'de açılıyor: $url"
  pc_run_ssh "cmd.exe /c start \"\" \"$url\"" 2>/dev/null \
    || pc_run_ssh "powershell -NoProfile -Command \"Start-Process '$url'\"" 2>/dev/null \
    || pc_run_ssh "xdg-open '$url' 2>/dev/null || sensible-browser '$url'"
  pause
}

pc_push_file() {
  ensure_pc || { pause; return; }
  local src dst
  read -r -p "Termux dosya yolu: " src
  read -r -p "PC hedef (örn: Desktop/dosya.txt): " dst
  [[ -z "$src" || ! -f "$src" ]] && { red "Dosya yok."; pause; return; }
  [[ -z "$dst" ]] && dst=$(basename "$src")
  if ! pc_ssh_available; then
    red "SSH kapalı; scp kullanılamaz."
    pause
    return
  fi
  scp -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$src" "$(pc_ssh_target):$dst"
  pause
}

pc_reboot() {
  ensure_pc || { pause; return; }
  read -r -p "PC yeniden başlatılsın mı? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return
  pc_run_ssh "shutdown /r /t 5 /c \"Termux tv-adb reboot\"" 2>/dev/null \
    || pc_run_ssh "sudo reboot" 2>/dev/null \
    || pc_run_ssh "reboot"
  yellow "Reboot komutu gönderildi."
  pause
}

pc_shutdown() {
  ensure_pc || { pause; return; }
  read -r -p "PC kapatılsın mı? [e/H]: " a
  [[ "$a" =~ ^[eEyY]$ ]] || return
  pc_run_ssh "shutdown /s /t 5 /c \"Termux tv-adb shutdown\"" 2>/dev/null \
    || pc_run_ssh "sudo shutdown -h now" 2>/dev/null \
    || pc_run_ssh "poweroff"
  yellow "Kapatma komutu gönderildi."
  pause
}

pc_smb_list() {
  ensure_pc || { pause; return; }
  if ! nc -z -w 2 "$PC_IP" 445 2>/dev/null; then
    red "SMB (445) kapalı veya erişilemiyor."
    pause
    return
  fi
  local user pass
  read -r -p "Kullanıcı (boş=misafir dene): " user
  if [[ -n "$user" ]]; then
    read -r -s -p "Parola: " pass
    echo
    smbclient -L "//$PC_IP" -U "$user%$pass" 2>/dev/null \
      || smbclient -L "//$PC_IP" -U "$user" 2>/dev/null
  else
    smbclient -L "//$PC_IP" -N 2>/dev/null
  fi
  pause
}

pc_smb_push() {
  ensure_pc || { pause; return; }
  if ! nc -z -w 2 "$PC_IP" 445 2>/dev/null; then
    red "SMB (445) kapalı."
    pause
    return
  fi
  local src share remote user pass
  read -r -p "Termux dosya yolu: " src
  read -r -p "Paylaşım adı (örn: Public): " share
  read -r -p "Uzak dosya adı [$(basename "${src:-file}")]: " remote
  remote=${remote:-$(basename "$src")}
  [[ -z "$src" || ! -f "$src" || -z "$share" ]] && { red "Dosya/paylaşım gerekli."; pause; return; }
  read -r -p "Kullanıcı (boş=misafir): " user
  if [[ -n "$user" ]]; then
    read -r -s -p "Parola: " pass
    echo
    smbclient "//$PC_IP/$share" -U "$user%$pass" -c "put \"$src\" \"$remote\"" 2>/dev/null
  else
    smbclient "//$PC_IP/$share" -N -c "put \"$src\" \"$remote\"" 2>/dev/null
  fi
  pause
}

pc_http_ping() {
  ensure_pc || { pause; return; }
  local path
  read -r -p "HTTP yol [/]: " path
  path=${path:-/}
  cyan "GET http://${PC_IP}${path}"
  if need_cmd curl; then
    curl -sS -m 8 -I "http://${PC_IP}${path}" || red "HTTP yanıt yok."
  elif need_cmd wget; then
    wget -S -O /dev/null -T 8 "http://${PC_IP}${path}" 2>&1 | head -n 15
  else
    red "curl/wget yok. pkg install curl"
  fi
  pause
}

pc_hosts_hint() {
  cat <<'EOF'

PC'de domain yönlendirme (Windows, yönetici Notepad):
  C:\Windows\System32\drivers\etc\hosts

Satır ekle:
  192.168.1.50  ornek.com

Linux/macOS:
  /etc/hosts

SSH açıksa uzaktan (Windows PowerShell yönetici):
  Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "192.168.1.50 ornek.com"

EOF
  pause
}

pc_enable_hint() {
  cat <<'EOF'

Windows PC'de uzaktan erişim açma (kendi PC'n):

1) OpenSSH Server (PowerShell yönetici):
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service -Name sshd -StartupType Automatic
   New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (sshd)" `
     -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

2) Uzaktan Masaüstü (RDP):
   Sistem → Uzaktan → Uzaktan Masaüstü'ne izin ver
   (Termux'tan RDP istemcisi ile bağlan: pkg install freerdp)

3) Dosya paylaşımı (SMB):
   Klasör → Özellikler → Paylaşım → Ağ üzerinden paylaş
   Gelişmiş paylaşım + izin ver

4) Wake-on-LAN:
   BIOS: Wake on LAN açık
   Aygıt Yöneticisi → Ağ kartı → Güç yönetimi →
   "Bu aygıtın bilgisayarı uyandırmasına izin ver"

OpenSSH yokken bu menüden yapılabilenler:
  - Wake-on-LAN (MAC kayıtlıysa)
  - Ping / port tarama
  - Ağ taraması (RDP/SMB/SSH açık PC bul)
  - SMB açıksa dosya gönder (parola/paylaşım gerekir)

EOF
  pause
}

pc_menu() {
  while true; do
    clear 2>/dev/null || true
    cyan "======================================"
    cyan "   Termux → PC Menüsü"
    cyan "======================================"
    echo " Kayıtlı PC : $(current_pc)"
    echo " SSH user   : $(load_pc_user)"
    echo " Algılanan ağ: $(get_subnet)"
    echo
    echo " --- OpenSSH gerekmez ---"
    echo " 1) PC IP / MAC kaydet"
    echo " 2) Ping at"
    echo " 3) PC servis taraması (22/445/3389...)"
    echo " 4) Ağı tara (PC adayları)"
    echo " 5) Wake-on-LAN (uyandır)"
    echo " 6) HTTP başlık isteği (curl)"
    echo " 7) hosts dosyası ipuçları"
    echo
    echo " --- SSH açıksa ---"
    echo " 8) SSH shell"
    echo " 9) Uzaktan komut çalıştır"
    echo "10) URL aç (tarayıcı)"
    echo "11) Dosya gönder (scp)"
    echo "12) Yeniden başlat"
    echo "13) Kapat"
    echo
    echo " --- SMB (445) açıksa ---"
    echo "14) Paylaşımları listele"
    echo "15) Dosya gönder (smb)"
    echo
    echo "16) Windows'ta SSH/RDP/SMB açma ipuçları"
    echo " 0) Ana menüye dön"
    echo
    read -r -p "Seçim: " p
    case "$p" in
      1) pc_set_target ;;
      2) pc_ping ;;
      3) pc_scan_services ;;
      4) pc_scan_network ;;
      5) pc_wake ;;
      6) pc_http_ping ;;
      7) pc_hosts_hint ;;
      8) pc_shell ;;
      9) pc_run_cmd ;;
      10) pc_open_url ;;
      11) pc_push_file ;;
      12) pc_reboot ;;
      13) pc_shutdown ;;
      14) pc_smb_list ;;
      15) pc_smb_push ;;
      16) pc_enable_hint ;;
      0) return ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
    esac
  done
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
    echo "12) Herhangi bir URL aç"
    echo "13) Proxy durumunu göster"
    echo "14) HTTP proxy ayarla"
    echo "15) HTTP proxy kapat"
    echo "16) Domain yönlendir (hosts, root)"
    echo "17) hosts yedeğini geri al (root)"
    echo "18) Ses: mute"
    echo "19) Ses: tam ses"
    echo "20) Arka planda ses çal"
    echo "21) Sesi / medyayı durdur"
    echo "22) Ters kumanda AÇ (fiziksel, root)"
    echo "23) Ters kumanda KAPAT (geri al)"
    echo "24) Saka / test eglence menusu"
    echo "25) Wi-Fi kapat"
    echo "26) Wi-Fi ac"
    echo "27) Yeniden başlat (reboot)"
    echo "28) TV'de TCP ADB açma ipuçları"
    echo "29) Bağlantıyı kes"
    echo "30) PC menüsü (SSH/RDP/SMB/WOL)"
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
      12) open_url ;;
      13) show_proxy ;;
      14) set_proxy ;;
      15) clear_proxy ;;
      16) hosts_redirect ;;
      17) hosts_restore ;;
      18) volume_mute ;;
      19) volume_max ;;
      20) play_audio_bg ;;
      21) stop_audio ;;
      22) reverse_remote_apply ;;
      23) reverse_remote_restore ;;
      24) prank_menu ;;
      25) wifi_disable; pause ;;
      26) wifi_enable; pause ;;
      27) reboot_device ;;
      28) enable_tcp_hint ;;
      29) disconnect_all ;;
      30) pc_menu ;;
      0) green "Görüşürüz."; exit 0 ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
    esac
  done
}

main_menu
