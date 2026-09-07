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
      0) return ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
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
    echo "16) Ters kumanda AÇ (fiziksel, root)"
    echo "17) Ters kumanda KAPAT (geri al)"
    echo "18) Saka / test eglence menusu"
    echo "19) Yeniden başlat (reboot)"
    echo "20) TV'de TCP ADB açma ipuçları"
    echo "21) Bağlantıyı kes"
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
      16) reverse_remote_apply ;;
      17) reverse_remote_restore ;;
      18) prank_menu ;;
      19) reboot_device ;;
      20) enable_tcp_hint ;;
      21) disconnect_all ;;
      0) green "Görüşürüz."; exit 0 ;;
      *) red "Geçersiz seçim."; sleep 1 ;;
    esac
  done
}

main_menu
