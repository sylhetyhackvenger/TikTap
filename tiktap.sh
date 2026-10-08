#!/usr/bin/env bash
set -o pipefail

if command -v locale >/dev/null 2>&1; then
    _u=$(locale -a 2>/dev/null | grep -iE 'utf-?8' | head -n1)
    if [[ -n "$_u" ]]; then export LC_ALL="$_u"; export LANG="$_u"
    else export LC_ALL=C.UTF-8; export LANG=C.UTF-8; fi
fi

ESC=$'\033'
nc="${ESC}[0m"
bold="${ESC}[1m"
dim="${ESC}[2m"
italic="${ESC}[3m"
underline="${ESC}[4m"

c_cyan="${ESC}[38;5;51m"
c_blue="${ESC}[38;5;39m"
c_deep="${ESC}[38;5;27m"
c_mid="${ESC}[38;5;33m"
c_green="${ESC}[38;5;46m"
c_lime="${ESC}[38;5;118m"
c_purple="${ESC}[38;5;141m"
c_magenta="${ESC}[38;5;201m"
c_pink="${ESC}[38;5;213m"
c_yellow="${ESC}[38;5;226m"
c_gold="${ESC}[38;5;220m"
c_orange="${ESC}[38;5;214m"
c_red="${ESC}[38;5;196m"
c_crimson="${ESC}[38;5;160m"
c_grey="${ESC}[38;5;244m"
c_dgrey="${ESC}[38;5;238m"
c_white="${ESC}[38;5;255m"
c_ice="${ESC}[38;5;159m"
bg_section="${ESC}[48;5;236m"

need=()
for cmd in curl jq awk grep sed fold tput wc sort cut tr head tail date; do
    command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
done
if (( ${#need[@]} )); then
    printf "%s[!] Missing dependencies:%s %s\n" "$c_red$bold" "$nc" "${need[*]}" >&2
    printf "    install with: pkg install %s\n" "${need[*]}" >&2
    exit 1
fi

if curl --version 2>/dev/null | grep -qiE 'busybox|brotli.*no'; then
    printf '%s[!] Warning:%s your curl may not decode Brotli. Retries without --compressed are enabled.\n' \
        "$c_yellow$bold" "$nc" >&2
fi

UA_POOL=(
"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0"
"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
"Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:122.0) Gecko/20100101 Firefox/122.0"
"Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1"
"Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile Safari/537.36"
)
UA_COUNT=${#UA_POOL[@]}
UA_LANG_POOL=("en-US,en;q=0.9" "en-GB,en;q=0.9" "en-CA,en;q=0.9" "en-AU,en;q=0.9")

pick_ua()   { printf '%s' "${UA_POOL[$((RANDOM % UA_COUNT))]}"; }
pick_lang() { printf '%s' "${UA_LANG_POOL[$((RANDOM % ${#UA_LANG_POOL[@]}))]}"; }

TERM_WIDTH=$(tput cols 2>/dev/null || echo 100)
(( TERM_WIDTH < 80 ))  && TERM_WIDTH=80
(( TERM_WIDTH > 160 )) && TERM_WIDTH=160
INNER=$((TERM_WIDTH - 2))

MAX_POSTS=12
MAX_FOLLOWERS=10
MAX_FOLLOWING=10
MAX_COMMENTS=5

SITES_FILE="${SITES_FILE:-sites.json}"
CROSS_TIMEOUT="${CROSS_TIMEOUT:-12}"
CROSS_UA="${CROSS_UA:-$(pick_ua)}"
CROSS_CONCURRENCY="${CROSS_CONCURRENCY:-6}"
CROSS_RETRY="${CROSS_RETRY:-2}"
CROSS_REPORT_TSV="${CROSS_REPORT_TSV:-cross_report.tsv}"
CROSS_REPORT_JSONL="${CROSS_REPORT_JSONL:-cross_report.jsonl}"
CROSS_REPORT_ERR="${CROSS_REPORT_ERR:-cross_report.err}"
CROSS_WAYBACK="${CROSS_WAYBACK:-1}"
CROSS_TLS="${CROSS_TLS:-1}"
CROSS_DNS="${CROSS_DNS:-1}"

DORK_ENGINE="${DORK_ENGINE:-duckduckgo}"
DORK_MAX_RESULTS="${DORK_MAX_RESULTS:-10}"
DORK_TIMEOUT="${DORK_TIMEOUT:-15}"
DORK_FETCH="${DORK_FETCH:-1}"
DORK_SLEEP="${DORK_SLEEP:-1}"

strip_ansi() { printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
vis() { local s; s=$(strip_ansi "$1"); printf '%d' "${#s}"; }

pad_to() {
    local str="$1" width="$2"
    local vlen; vlen=$(vis "$str")
    local pad=$((width - vlen))
    (( pad < 0 )) && pad=0
    printf '%s%*s' "$str" "$pad" ""
}

urlencode() {
    local s="$1" out="" c
    local i len=${#s}
    for (( i=0; i<len; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

_sha1() {
    if command -v sha1sum >/dev/null 2>&1; then sha1sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 1 | awk '{print $1}'
    else printf 'nohash'
    fi
}

pretty_num() {
    local n="$1"
    [[ -z "$n" || ! "$n" =~ ^-?[0-9]+$ ]] && { printf '%s' "${n:-N/A}"; return; }
    awk -v n="$n" 'BEGIN{
        if(n>=1e9) printf "%.2fB", n/1e9;
        else if(n>=1e6) printf "%.2fM", n/1e6;
        else if(n>=1e3) printf "%.2fK", n/1e3;
        else printf "%d", n;
    }'
}

bool_str() {
    case "$1" in
        true|True|1)   printf 'yes' ;;
        false|False|0|"") printf 'no' ;;
        *) printf '%s' "$1" ;;
    esac
}

to_date() {
    local t="$1"
    if [[ -n "$t" && "$t" =~ ^[0-9]+$ && "$t" -gt 0 ]]; then
        date -d "@$t" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || printf '%s' "$t"
    else
        printf 'N/A'
    fi
}

top_border()    { printf '%s+' "$c_deep"; printf '%*s' "$INNER" '' | tr ' ' '='; printf '+%s\n' "$nc"; }
bottom_border() { printf '%s+' "$c_deep"; printf '%*s' "$INNER" '' | tr ' ' '='; printf '+%s\n' "$nc"; }
divider()       { printf '%s+' "$c_deep"; printf '%*s' "$INNER" '' | tr ' ' '-'; printf '+%s\n' "$nc"; }

section() {
    local title="$1" color="$2"
    local tag="[ ${title} ]"
    local inner_content=$(( INNER - 2 ))
    local head=" ${tag} "
    local hlen; hlen=$(vis "$head")
    local fill=$(( inner_content - hlen ))
    (( fill < 0 )) && fill=0
    printf '%s|%s%s%s%s%s%s' \
        "$c_deep" "$nc" "$bg_section" "$color$bold" "$head" "$nc" "$bg_section"
    printf '%s' "$nc"
    printf '%s' "$c_dgrey"
    printf '%*s' "$fill" '' | tr ' ' '-'
    printf '%s' "$nc"
    printf '%s|%s\n' "$c_deep" "$nc"
}

row() {
    local key="$1" val="$2" vc="${3:-$c_white}" glyph="${4:-*}"
    local key_w=22
    local val_max=$(( INNER - 2 - 1 - 1 - 1 - key_w - 3 - 1 ))
    (( val_max < 4 )) && val_max=4

    local first="${val:0:$val_max}"
    printf '%s|%s %s%s%s %s%-*s%s %s:%s ' \
        "$c_deep" "$nc" \
        "$c_dgrey" "$glyph" "$nc" \
        "$c_cyan" "$key_w" "$key" "$nc" \
        "$c_dgrey" "$nc"
    local colored="${vc}${first}${nc}"
    local padded; padded=$(pad_to "$colored" "$val_max")
    printf '%s %s|%s\n' "$padded" "$c_deep" "$nc"

    local rest="${val:$val_max}"
    while [[ -n "$rest" ]]; do
        local chunk="${rest:0:$val_max}"
        rest="${rest:$val_max}"
        printf '%s|%s %s:%s ' "$c_deep" "$nc" "$c_dgrey" "$nc"
        local colored="${vc}${chunk}${nc}"
        local padded; padded=$(pad_to "$colored" "$val_max")
        printf '%s %s|%s\n' "$padded" "$c_deep" "$nc"
    done
}

para() {
    local text="$1" color="${2:-$c_white}"
    local avail=$(( INNER - 4 ))
    if [[ -z "$text" || "$text" == "N/A" ]]; then
        local colored="${c_grey}${italic}(no biography)${nc}"
        local line; line=$(pad_to "  ${colored}" "$INNER")
        printf '%s|%s%s%s|%s\n' "$c_deep" "$nc" "$line" "$c_deep" "$nc"
        return
    fi
    printf '%s' "$text" | fold -s -w "$avail" | while IFS= read -r line; do
        local colored="${color}${line}${nc}"
        local padded; padded=$(pad_to "  ${colored}" "$INNER")
        printf '%s|%s%s%s|%s\n' "$c_deep" "$nc" "$padded" "$c_deep" "$nc"
    done
}

banner() {
    clear
    printf '\n'
    printf '%s%s' "$c_cyan" "$bold"
    cat <<'EOF'
    ████████▀▀▀████
    ████████────▀██
    ████████──█▄──█
    ███▀▀▀██──█████
    █▀──▄▄██──█████
    █──█████──█████
    █▄──▀▀▀──▄█████
    ███▄▄▄▄▄███████
EOF
    printf '%s\n' "$nc"
    printf '    %s%s###%s  %s%sT i k T a p%s  %s%s###%s\n' \
        "$c_magenta$bold" "$c_magenta" "$nc" \
        "$c_white$bold" "$c_white" "$nc" \
        "$c_magenta$bold" "$c_magenta" "$nc"
    printf '    %sTikTok User Info Scraper%s  %s|%s  %sTikTok Scraper & Username Reconnaissance%s\n' \
        "$c_ice" "$nc" "$c_dgrey" "$nc" "$c_green$bold" "$nc"
    printf '    %sgithub.com/%ssylhetyhackvenger%s\n\n' "$c_dgrey" "$c_cyan" "$nc"
}

prompt_user() {
    printf '  %s%s+-[ %sTARGET%s ]%s\n' "$c_deep" "$bold" "$c_magenta" "$nc$c_deep" "$nc"
    printf '  %s|%s\n' "$c_deep" "$nc"
    printf '  %s|%s  %sEnter TikTok username%s %s(no @ needed)%s\n' \
        "$c_deep" "$nc" "$c_ice" "$nc" "$c_dgrey" "$nc"
    printf '  %s|%s  %s> %s' "$c_deep" "$nc" "$c_cyan" "$nc"
    read -r username
    username="${username//@/}"
    username="${username// /}"
    printf '  %s|%s\n' "$c_deep" "$nc"
    printf '  %s+--------------------------------------------------%s\n\n' "$c_deep" "$nc"
}

ensure_sites_file() {
    [[ -s "$SITES_FILE" ]] && return 0
    cat > "$SITES_FILE" <<'JSON'
[
 {"name":"Instagram","url":"https://www.instagram.com/{u}/","method":"meta","ok":"og:title","not_ok":"Page Not Found"},
 {"name":"X (Twitter)","url":"https://x.com/{u}","method":"meta","ok":"og:title","not_ok":"This account doesn"},
 {"name":"Facebook","url":"https://www.facebook.com/{u}","method":"meta","ok":"og:title","not_ok":"content isn't available"},
 {"name":"LinkedIn","url":"https://www.linkedin.com/in/{u}","method":"meta","ok":"og:title","not_ok":"Page not found"},
 {"name":"GitHub","url":"https://api.github.com/users/{u}","method":"api","ok":"\"login\"","not_ok":"Not Found"},
 {"name":"Snapchat","url":"https://www.snapchat.com/add/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Reddit","url":"https://www.reddit.com/user/{u}/about.json","method":"api","ok":"\"name\"","not_ok":"\"error\": 404"},
 {"name":"Pinterest","url":"https://www.pinterest.com/{u}/","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"YouTube","url":"https://www.youtube.com/@{u}","method":"meta","ok":"og:title","not_ok":"404 Not Found"},
 {"name":"Twitch","url":"https://www.twitch.tv/{u}","method":"meta","ok":"og:title","not_ok":"404"},
 {"name":"Medium","url":"https://medium.com/@{u}","method":"meta","ok":"og:title","not_ok":"404"},
 {"name":"Tumblr","url":"https://{u}.tumblr.com/","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Flickr","url":"https://www.flickr.com/people/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Vimeo","url":"https://vimeo.com/{u}","method":"meta","ok":"og:title","not_ok":"404"},
 {"name":"SoundCloud","url":"https://soundcloud.com/{u}","method":"meta","ok":"og:title","not_ok":"404"},
 {"name":"Spotify","url":"https://open.spotify.com/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Telegram","url":"https://t.me/{u}","method":"tgme","ok":"tgme_page_title","not_ok":"tgme_page_icon"},
 {"name":"Discord","url":"https://discord.com/users/{u}","method":"status","ok_status":"200","not_status":"404"},
 {"name":"Steam","url":"https://steamcommunity.com/id/{u}","method":"meta","ok":"og:title","not_ok":"could not be found"},
 {"name":"Roblox","url":"https://users.roblox.com/v1/usernames/users","method":"status","ok_status":"200","not_status":"404"},
 {"name":"DeviantArt","url":"https://www.deviantart.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Behance","url":"https://www.behance.net/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Dribbble","url":"https://dribbble.com/{u}","method":"meta","ok":"og:title","not_ok":"404"},
 {"name":"Quora","url":"https://www.quora.com/profile/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Mastodon","url":"https://mastodon.social/@{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Threads","url":"https://www.threads.net/@{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Bluesky","url":"https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle={u}.bsky.social","method":"api","ok":"\"did\"","not_ok":"InvalidRequest"},
 {"name":"Clubhouse","url":"https://www.clubhouse.com/@{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"VK","url":"https://vk.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Odnoklassniki","url":"https://ok.ru/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Weibo","url":"https://weibo.com/{u}","method":"body","ok":"\"screen_name\"","not_ok":"抱歉，此用户不存在"},
 {"name":"Douyin","url":"https://www.douyin.com/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Kuaishou","url":"https://www.kuaishou.com/profile/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Bilibili","url":"https://api.bilibili.com/x/web-interface/card?mid={u}","method":"status","ok_status":"200","not_status":"404"},
 {"name":"Line","url":"https://line.me/ti/p/~{u}","method":"body","ok":"profile","not_ok":"此 ID 目前無法使用"},
 {"name":"Kakao","url":"https://story.kakao.com/{u}","method":"meta","ok":"og:title","not_ok":"로그인"},
 {"name":"WeChat","url":"https://weixin.qq.com/{u}","method":"body","ok":"weixin","not_ok":"not found"},
 {"name":"Signal","url":"https://signal.me/#p/{u}","method":"status","ok_status":"200","not_status":"404"},
 {"name":"WhatsApp","url":"https://wa.me/{u}","method":"body","ok":"phone_number","not_ok":"invalid"},
 {"name":"Skype","url":"https://join.skype.com/invite/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Zoom","url":"https://zoom.us/u/{u}","method":"body","ok":"profile","not_ok":"not found"},
 {"name":"Meetup","url":"https://www.meetup.com/members/{u}","method":"body","ok":"memberId","not_ok":"Page Not Found"},
 {"name":"Eventbrite","url":"https://www.eventbrite.com/o/{u}","method":"body","ok":"organizer_id","not_ok":"Page Not Found"},
 {"name":"Goodreads","url":"https://www.goodreads.com/{u}","method":"body","ok":"user_id","not_ok":"Page not found"},
 {"name":"Last.fm","url":"https://www.last.fm/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Mixcloud","url":"https://www.mixcloud.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Bandcamp","url":"https://bandcamp.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Patreon","url":"https://www.patreon.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Ko-fi","url":"https://ko-fi.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"BuyMeACoffee","url":"https://www.buymeacoffee.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Messenger","url":"https://www.messenger.com/t/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Bigo Live","url":"https://www.bigo.tv/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"imo","url":"https://imo.im/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Chamet","url":"https://www.chamet.com/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Likee","url":"https://likee.video/@{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Poppo Live","url":"https://www.poppo.live/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Kukie","url":"https://kukie.app/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"OmeTV","url":"https://ome.tv/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Moj","url":"https://www.mojapp.in/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Toki","url":"https://toki.app/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Viber","url":"https://viber.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"IMO Messenger","url":"https://imo.im/chat/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Nimbuzz","url":"https://nimbuzz.com/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Helo","url":"https://helo-app.com/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"ShareChat","url":"https://sharechat.com/profile/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Kwai","url":"https://www.kwai.com/@{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Bongo","url":"https://www.bongobd.com/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Toot","url":"https://toot.com.bd/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Vibe","url":"https://vibe.com.bd/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"},
 {"name":"Nagad Social","url":"https://www.nagad.com.bd/user/{u}","method":"meta","ok":"og:title","not_ok":"not found"}
]
JSON
}

fetch_and_parse() {
    local user="$1"
    local COOKIE_JAR
    COOKIE_JAR="$(mktemp -t tiktap.XXXXXX 2>/dev/null || mktemp)"
    trap 'rm -f "$COOKIE_JAR"' EXIT INT TERM

    local ua lang url
    ua="$(pick_ua)"
    lang="$(pick_lang)"
    url="https://www.tiktok.com/@${user}?isUniqueId=true&isSecured=true"

    source_code="$(curl -sL \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -A "$ua" \
        -H "Accept-Language: $lang" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        -H "DNT: 1" \
        -H "Upgrade-Insecure-Requests: 1" \
        --compressed \
        --max-time 25 \
        "$url" | LC_ALL=C tr -d '\0')"

    resp_headers="$(curl -sIL \
        -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
        -A "$ua" \
        -H "Accept-Language: $lang" \
        --compressed \
        --max-time 15 \
        "$url" 2>/dev/null | LC_ALL=C tr -d '\0')"

    extract() { printf '%s' "$source_code" | grep -oP "$1" | head -n1 | sed "$2"; }
    cookie_val() {
        [[ ! -s "$COOKIE_JAR" ]] && return
        awk -v k="$1" '$6==k {print $7}' "$COOKIE_JAR" | tail -n1
    }
    header_val() { printf '%s' "$resp_headers" | grep -i "^$1:" | head -n1 | cut -d' ' -f2- | tr -d '\r'; }

    id=$(extract '"id":"\d+"' 's/"id":"//;s/"//')
    [[ -z "$id" ]] && return 1

    uniqueId=$(extract '"uniqueId":"[^"]*"' 's/"uniqueId":"//;s/"//')
    nickname=$(extract '"nickname":"[^"]*"' 's/"nickname":"//;s/"//')
    avatarLarger=$(extract '"avatarLarger":"[^"]*"' 's/"avatarLarger":"//;s/"//')
    avatarMedium=$(extract '"avatarMedium":"[^"]*"' 's/"avatarMedium":"//;s/"//')
    avatarThumb=$(extract '"avatarThumb":"[^"]*"' 's/"avatarThumb":"//;s/"//')
    signature=$(extract '"signature":"[^"]*"' 's/"signature":"//;s/"//')
    privateAccount=$(extract '"privateAccount":[^,]*' 's/"privateAccount"://')
    secret=$(extract '"secret":[^,]*' 's/"secret"://')
    verified=$(extract '"verified":[^,]*' 's/"verified"://')
    language_code=$(extract '"language":"[^"]*"' 's/"language":"//;s/"//')
    secUid=$(extract '"secUid":"[^"]*"' 's/"secUid":"//;s/"//')
    diggCount=$(extract '"diggCount":[^,]*' 's/"diggCount"://')
    followerCount=$(extract '"followerCount":[^,]*' 's/"followerCount"://')
    followingCount=$(extract '"followingCount":[^,]*' 's/"followingCount"://')
    heartCount=$(extract '"heartCount":[^,]*' 's/"heartCount"://')
    videoCount=$(extract '"videoCount":[^,]*' 's/"videoCount"://')
    friendCount=$(extract '"friendCount":[^,}]*' 's/"friendCount"://')
    createTime=$(extract '"createTime":\d+' 's/"createTime"://')
    uniqueIdModifyTime=$(extract '"uniqueIdModifyTime":\d+' 's/"uniqueIdModifyTime"://')
    nickNameModifyTime=$(extract '"nickNameModifyTime":\d+' 's/"nickNameModifyTime"://')
    signatureModifyTime=$(extract '"signatureModifyTime":\d+' 's/"signatureModifyTime"://')
    avatarModifyTime=$(extract '"avatarModifyTime":\d+' 's/"avatarModifyTime"://')
    commentSetting=$(extract '"commentSetting":[^,]*' 's/"commentSetting"://')
    duetSetting=$(extract '"duetSetting":[^,]*' 's/"duetSetting"://')
    stitchSetting=$(extract '"stitchSetting":[^,]*' 's/"stitchSetting"://')
    openFavorite=$(extract '"openFavorite":[^,]*' 's/"openFavorite"://')
    isADVirtual=$(extract '"isADVirtual":[^,}]*' 's/"isADVirtual"://')
    isEmbedBanned=$(extract '"isEmbedBanned":[^,}]*' 's/"isEmbedBanned"://')
    ttSeller=$(extract '"ttSeller":[^,}]*' 's/"ttSeller"://')
    ftcUser=$(extract '"ftcUser":[^,}]*' 's/"ftcUser"://')
    bioLink=$(extract '"bioLink":{"link":"[^"]*"' 's/.*"link":"//;s/"//')
    roomId=$(extract '"roomId":"[^"]*"' 's/"roomId":"//;s/"//')
    commerceUser=$(extract '"commerceUserInfo":{[^}]*}' 's/"commerceUserInfo"://')

    csrf_token=$(extract '"csrfToken":"[^"]*"' 's/"csrfToken":"//;s/"//')
    _signature=$(extract '"_signature":"[^"]*"' 's/"_signature":"//;s/"//')
    verifyFp_html=$(extract '"verifyFp":"[^"]*"' 's/"verifyFp":"//;s/"//')
    odnFp_html=$(extract '"odnFp":"[^"]*"' 's/"odnFp":"//;s/"//')

    ttwid=$(cookie_val "ttwid")
    tt_webid=$(cookie_val "tt_webid")
    s_v_web_id=$(cookie_val "s_v_web_id")
    msToken_cookie=$(cookie_val "msToken")
    webid_cookie=$(cookie_val "webid")
    sessionid_cookie=$(cookie_val "sessionid")
    sessionid_ss_cookie=$(cookie_val "sessionid_ss")
    sid_tt_cookie=$(cookie_val "sid_tt")
    uid_tt_cookie=$(cookie_val "uid_tt")
    uid_tt_ss_cookie=$(cookie_val "uid_tt_ss")
    sid_guard_cookie=$(cookie_val "sid_guard")
    passport_csrf_cookie=$(cookie_val "passport_csrf_token")
    csrf_session_cookie=$(cookie_val "csrf_session_id")

    server_hdr=$(header_val "server")
    date_hdr=$(header_val "date")
    content_type=$(header_val "content-type")
    x_tt_logid=$(header_val "x-tt-logid")
    x_tt_trace=$(header_val "x-tt-trace-id")
    x_tt_timing=$(header_val "x-tt-timing")
    x_tt_region=$(header_val "x-tt-region")

    webmssdk_url=$(printf '%s' "$source_code" | grep -oP 'https://[^"]*webmssdk[^"]*\.js' | head -n1)
    webmssdk_version="N/A"
    if [[ -n "$webmssdk_url" ]]; then
        local js
        js="$(curl -s --max-time 15 -A "$ua" "$webmssdk_url" | LC_ALL=C tr -d '\0')"
        webmssdk_version=$(printf '%s' "$js" | grep -oP 'version["\x27\s:=]+\K[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        [[ -z "$webmssdk_version" ]] && webmssdk_version="N/A"
    fi

    webapp_url=$(printf '%s' "$source_code" | grep -oP 'https://[^"]*webapp[^"]*\.js' | head -n1)
    webapp_version="N/A"
    webapp_obfuscated="N/A"
    if [[ -n "$webapp_url" ]]; then
        local js
        js="$(curl -s --max-time 15 -A "$ua" "$webapp_url" | LC_ALL=C tr -d '\0')"
        webapp_version=$(printf '%s' "$js" | grep -oP 'version["\x27\s:=]+\K[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        webapp_obfuscated=$(printf '%s' "$js" | grep -oP 'obfuscated["\x27\s:=]+\K[0-9a-f]{6,}' | head -n1)
        [[ -z "$webapp_version" ]] && webapp_version="N/A"
        [[ -z "$webapp_obfuscated" ]] && webapp_obfuscated="N/A"
    fi

    createTime_h=$(to_date "$createTime")
    uniqueIdModifyTime_h=$(to_date "$uniqueIdModifyTime")
    nickNameModifyTime_h=$(to_date "$nickNameModifyTime")
    signatureModifyTime_h=$(to_date "$signatureModifyTime")
    avatarModifyTime_h=$(to_date "$avatarModifyTime")

    if [[ -n "$language_code" && -f languages.json ]]; then
        local lname
        lname=$(jq -r --arg lang "$language_code" '.[] | select(.code == $lang) | .name' languages.json 2>/dev/null)
        language="${lname:-Unknown (Code: $language_code)}"
    else
        language="${language_code:-N/A}"
    fi

    region_code=$(printf '%s' "$source_code" | grep -oP '"ttSeller":false,"region":"\K[^"]+')
    if [[ -n "$region_code" && -f countries.json ]]; then
        local cname
        cname=$(jq -r --arg region "$region_code" '.[] | select(.code == $region) | .name' countries.json 2>/dev/null)
        region="${cname:-Unknown (Code: $region_code)}"
    else
        region="${region_code:-N/A}"
    fi

    local token_qs=""
    [[ -n "$msToken_cookie" ]] && token_qs+="&msToken=$(urlencode "$msToken_cookie")"
    [[ -n "$ttwid" ]]          && token_qs+="&ttwid=$(urlencode "$ttwid")"
    [[ -n "$verifyFp_html" ]]  && token_qs+="&verifyFp=$(urlencode "$verifyFp_html")"

    posts_json=""
    followers_json=""
    following_json=""
    comments_json=""

    if [[ -n "$secUid" && "$privateAccount" != "true" ]]; then
        local posts_url="https://www.tiktok.com/api/post/item_list/?aid=1988&count=${MAX_POSTS}&secUid=$(urlencode "$secUid")&cursor=0${token_qs}"
        posts_json="$(curl -sL -A "$ua" -H "Accept-Language: $lang" -H "Referer: https://www.tiktok.com/@${user}" -b "$COOKIE_JAR" --compressed --max-time 20 "$posts_url" | LC_ALL=C tr -d '\0')"

        local fol_url="https://www.tiktok.com/api/user/list/?aid=1988&count=${MAX_FOLLOWERS}&secUid=$(urlencode "$secUid")&type=1&cursor=0${token_qs}"
        followers_json="$(curl -sL -A "$ua" -H "Accept-Language: $lang" -H "Referer: https://www.tiktok.com/@${user}" -b "$COOKIE_JAR" --compressed --max-time 20 "$fol_url" | LC_ALL=C tr -d '\0')"

        local folg_url="https://www.tiktok.com/api/user/list/?aid=1988&count=${MAX_FOLLOWING}&secUid=$(urlencode "$secUid")&type=0&cursor=0${token_qs}"
        following_json="$(curl -sL -A "$ua" -H "Accept-Language: $lang" -H "Referer: https://www.tiktok.com/@${user}" -b "$COOKIE_JAR" --compressed --max-time 20 "$folg_url" | LC_ALL=C tr -d '\0')"

        local first_aweme
        first_aweme=$(printf '%s' "$posts_json" | jq -r '.itemList[0].id // empty' 2>/dev/null)
        if [[ -n "$first_aweme" ]]; then
            local c_url="https://www.tiktok.com/api/comment/list/?aid=1988&aweme_id=${first_aweme}&count=${MAX_COMMENTS}&cursor=0${token_qs}"
            comments_json="$(curl -sL -A "$ua" -H "Accept-Language: $lang" -H "Referer: https://www.tiktok.com/@${user}" -b "$COOKIE_JAR" --compressed --max-time 20 "$c_url" | LC_ALL=C tr -d '\0')"
        fi
    fi

    return 0
}

render_posts() {
    if [[ -z "$posts_json" ]]; then
        row "Status" "not fetched (private or no secUid)" "$c_dgrey"
        return
    fi
    local status
    status=$(printf '%s' "$posts_json" | jq -r '.statusCode // empty' 2>/dev/null)
    if [[ -z "$status" || "$status" != "0" ]]; then
        row "Status" "blocked or empty (statusCode=${status:-unknown})" "$c_red"
        return
    fi

    local n
    n=$(printf '%s' "$posts_json" | jq -r '.itemList | length' 2>/dev/null)
    row "Fetched" "$n latest public posts" "$c_white"
    local i=0
    while (( i < n && i < MAX_POSTS )); do
        local vid desc play digg cmt share col dur created
        vid=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].id // \"N/A\"" 2>/dev/null)
        desc=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].desc // \"(no caption)\"" 2>/dev/null)
        play=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].stats.playCount // 0" 2>/dev/null)
        digg=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].stats.diggCount // 0" 2>/dev/null)
        cmt=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].stats.commentCount // 0" 2>/dev/null)
        share=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].stats.shareCount // 0" 2>/dev/null)
        col=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].stats.collectCount // 0" 2>/dev/null)
        dur=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].video.duration // 0" 2>/dev/null)
        created=$(printf '%s' "$posts_json" | jq -r ".itemList[$i].createTime // 0" 2>/dev/null)
        local created_h; created_h=$(to_date "$created")
        printf '%s|%s\n' "$c_deep" "$nc"
        row "Video #$((i+1)) ID" "$vid" "$c_ice"
        row "Caption" "$desc" "$c_white"
        row "Views" "$play ($(pretty_num "$play"))" "$c_lime"
        row "Likes" "$digg ($(pretty_num "$digg"))" "$c_pink"
        row "Comments" "$cmt ($(pretty_num "$cmt"))" "$c_cyan"
        row "Shares" "$share ($(pretty_num "$share"))" "$c_yellow"
        row "Saves" "$col ($(pretty_num "$col"))" "$c_gold"
        row "Duration" "${dur} ms" "$c_white"
        row "Posted" "$created_h" "$c_white"
        (( i++ ))
    done
}

render_userlist() {
    local title="$1" json="$2"
    if [[ -z "$json" ]]; then
        row "${title} Status" "not fetched" "$c_dgrey"
        return
    fi
    local status
    status=$(printf '%s' "$json" | jq -r '.statusCode // empty' 2>/dev/null)
    if [[ -z "$status" || "$status" != "0" ]]; then
        row "${title} Status" "blocked (statusCode=${status:-unknown})" "$c_red"
        return
    fi
    local n
    n=$(printf '%s' "$json" | jq -r '.userList | length' 2>/dev/null)
    row "${title} Fetched" "$n accounts" "$c_white"
    local i=0
    while (( i < n )); do
        local uid nick ver sig
        uid=$(printf '%s' "$json" | jq -r ".userList[$i].user.uniqueId // \"N/A\"" 2>/dev/null)
        nick=$(printf '%s' "$json" | jq -r ".userList[$i].user.nickname // \"N/A\"" 2>/dev/null)
        ver=$(printf '%s' "$json" | jq -r ".userList[$i].user.verified // false" 2>/dev/null)
        sig=$(printf '%s' "$json" | jq -r ".userList[$i].user.signature // \"\"" 2>/dev/null)
        printf '%s|%s\n' "$c_deep" "$nc"
        row "User #$((i+1))" "@$uid" "$c_green"
        row "  Nickname" "$nick" "$c_white"
        row "  Verified" "$(bool_str "$ver")" "$c_cyan"
        row "  Bio" "$sig" "$c_ice"
        (( i++ ))
    done
}

render_comments() {
    if [[ -z "$comments_json" ]]; then
        row "Status" "not fetched (no post or blocked)" "$c_dgrey"
        return
    fi
    local status
    status=$(printf '%s' "$comments_json" | jq -r '.statusCode // empty' 2>/dev/null)
    if [[ -z "$status" || "$status" != "0" ]]; then
        row "Status" "blocked (statusCode=${status:-unknown})" "$c_red"
        return
    fi
    local n
    n=$(printf '%s' "$comments_json" | jq -r '.comments | length' 2>/dev/null)
    row "Fetched" "$n comments on latest video" "$c_white"
    local i=0
    while (( i < n && i < MAX_COMMENTS )); do
        local user text likes
        user=$(printf '%s' "$comments_json" | jq -r ".comments[$i].user.uniqueId // \"N/A\"" 2>/dev/null)
        text=$(printf '%s' "$comments_json" | jq -r ".comments[$i].text // \"\"" 2>/dev/null)
        likes=$(printf '%s' "$comments_json" | jq -r ".comments[$i].digg_count // 0" 2>/dev/null)
        printf '%s|%s\n' "$c_deep" "$nc"
        row "Comment #$((i+1))" "@$user (${likes} likes)" "$c_green"
        row "  Text" "$text" "$c_white"
        (( i++ ))
    done
}

_meta_content_from_file() {
    local file="$1" prop="$2"
    [[ ! -s "$file" ]] && return
    grep -oP "<meta[^>]+(?:property|name)=[\"']${prop}[\"'][^>]*>" "$file" 2>/dev/null \
        | head -n1 \
        | grep -oP 'content=["'"'"']\K[^"'"'"']+'
}

_page_title_from_file() {
    [[ ! -s "$1" ]] && return
    grep -oP '<title[^>]*>\K[^<]+' "$1" 2>/dev/null | head -n1
}

_dns_probe() {
    local host="$1" ip="" rev=""
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    fi
    if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2; exit}')
    fi
    [[ -z "$ip" ]] && ip="unknown"
    if command -v host >/dev/null 2>&1; then
        rev=$(host "$ip" 2>/dev/null | awk '/domain name pointer/{print $NF}')
    fi
    [[ -z "$rev" ]] && rev="unknown"
    printf '%s|%s' "$ip" "$rev"
}

_tls_probe() {
    local host="$1"
    [[ "$CROSS_TLS" != "1" ]] && { printf 'disabled||||'; return; }
    command -v openssl >/dev/null 2>&1 || { printf 'no-openssl||||'; return; }
    local out
    out="$(echo | timeout 8 openssl s_client -servername "$host" -connect "${host}:443" 2>/dev/null \
        | openssl x509 -noout -subject -issuer -dates 2>/dev/null)"
    [[ -z "$out" ]] && { printf 'failed||||'; return; }
    local subj iss nb na
    subj=$(printf '%s' "$out" | grep -m1 '^subject=' | sed 's/^subject=//')
    iss=$(printf '%s' "$out"  | grep -m1 '^issuer='  | sed 's/^issuer=//')
    nb=$(printf '%s' "$out"   | grep -m1 '^notBefore=' | sed 's/^notBefore=//')
    na=$(printf '%s' "$out"   | grep -m1 '^notAfter='  | sed 's/^notAfter=//')
    printf '%s|%s|%s|%s' "$subj" "$iss" "$nb" "$na"
}

_wayback_probe() {
    local url="$1"
    [[ "$CROSS_WAYBACK" != "1" ]] && { printf 'disabled||'; return; }
    local q
    q=$(curl -s --max-time 10 "https://archive.org/wayback/available?url=$(urlencode "$url")" 2>/dev/null | LC_ALL=C tr -d '\0')
    local snap ts
    snap=$(printf '%s' "$q" | grep -oP '"url":"\K[^"]+')
    ts=$(printf '%s' "$q"   | grep -oP '"timestamp":"\K[^"]+')
    printf '%s|%s' "${ts:-none}" "${snap:-none}"
}

_ua() {
    printf '%s' "${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
}

_scrape_instagram() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -s --max-time 15 \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36" \
        -H "X-IG-App-ID: 936619743392459" \
        -H "Accept: */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Referer: https://www.instagram.com/${user}/" \
        "https://i.instagram.com/api/v1/users/web_profile_info/?username=${user}" \
        -o "$tmp" 2>/dev/null
    if jq -e . "$tmp" >/dev/null 2>&1; then
        local n b av fc
        n=$(jq -r '.data.user.full_name // empty' "$tmp")
        b=$(jq -r '.data.user.biography // empty' "$tmp")
        av=$(jq -r '.data.user.profile_pic_url_hd // .data.user.profile_pic_url // empty' "$tmp")
        fc=$(jq -r '.data.user.edge_followed_by.count // empty' "$tmp")
        printf '%s\t%s\t%s\t\t%s' "$n" "$b" "$av" "$fc"
    else
        printf '\t\t\t\t'
    fi
    rm -f "$tmp"
}

_scrape_twitter() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -s --max-time 15 \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36" \
        -H "Accept: application/json" \
        "https://syndication.twitter.com/srv/timeline-profile/screen-name/${user}" \
        -o "$tmp" 2>/dev/null
    if jq -e . "$tmp" >/dev/null 2>&1; then
        local n b av
        n=$(jq -r '.props.pageProps.user.name // .user.name // empty' "$tmp")
        b=$(jq -r '.props.pageProps.user.description // .user.description // empty' "$tmp")
        av=$(jq -r '.props.pageProps.user.profile_image_url_https // .user.profile_image_url_https // empty' "$tmp")
        printf '%s\t%s\t%s\t\t' "$n" "$b" "$av"
    else
        printf '\t\t\t\t'
    fi
    rm -f "$tmp"
}

_scrape_youtube() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 -A "$(_ua)" -H "Accept-Language: en-US,en;q=0.9" \
        "https://www.youtube.com/@${user}" -o "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]]; then
        local n b av fc joined
        n=$(grep -oP '"channelMetadataRenderer":\{"title":"\K[^"]+' "$tmp" | head -n1)
        b=$(grep -oP '"description":"\K[^"]+' "$tmp" | head -n1 | sed 's/\\n/ /g; s/\\u0026/\&/g')
        av=$(grep -oP '"avatar":\{"thumbnails":\[\{"url":"\K[^"]+' "$tmp" | head -n1 | sed 's/\\u0026/\&/g')
        fc=$(grep -oP '"subscriberCountText":\{"simpleText":"\K[^"]+' "$tmp" | head -n1)
        joined=$(grep -oP '"joinedDateText":\{"runs":\[\{"text":"Joined \K[^"]+' "$tmp" | head -n1)
        printf '%s\t%s\t%s\t%s\t%s' "$n" "$b" "$av" "$joined" "$fc"
    else
        printf '\t\t\t\t'
    fi
    rm -f "$tmp"
}

_scrape_facebook() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36" \
        -H "Accept-Language: en-US,en;q=0.9" \
        "https://mbasic.facebook.com/${user}" -o "$tmp" 2>/dev/null
    local n b av
    n=$(_meta_content_from_file "$tmp" "og:title")
    b=$(_meta_content_from_file "$tmp" "og:description")
    av=$(_meta_content_from_file "$tmp" "og:image")
    [[ -z "$n" ]] && n=$(grep -oP '<title>\K[^<]+' "$tmp" | head -n1 | sed 's/ | Facebook//')
    printf '%s\t%s\t%s\t\t' "$n" "$b" "$av"
    rm -f "$tmp"
}

_scrape_linkedin() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 \
        -A "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" \
        "https://www.linkedin.com/in/${user}" -o "$tmp" 2>/dev/null
    local n b av
    n=$(_meta_content_from_file "$tmp" "og:title")
    b=$(_meta_content_from_file "$tmp" "og:description")
    av=$(_meta_content_from_file "$tmp" "og:image")
    printf '%s\t%s\t%s\t\t' "$n" "$b" "$av"
    rm -f "$tmp"
}

_scrape_reddit() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 -A "tiktap-scraper/1.0 (by /u/tiktap)" \
        "https://www.reddit.com/user/${user}/about.json" -o "$tmp" 2>/dev/null
    if jq -e . "$tmp" >/dev/null 2>&1; then
        local n b av fc created
        n=$(jq -r '.data.subreddit.title // .data.name // empty' "$tmp")
        b=$(jq -r '.data.subreddit.public_description // empty' "$tmp")
        av=$(jq -r '.data.subreddit.icon_img // .data.icon_img // empty' "$tmp" | sed 's/?.*//')
        fc=$(jq -r '.data.subreddit.subscribers // .data.total_karma // empty' "$tmp")
        created=$(jq -r '.data.created_utc // empty' "$tmp")
        if [[ -n "$created" && "$created" =~ ^[0-9.]+$ ]]; then
            created=$(date -d "@${created%.*}" +"%Y-%m-%d" 2>/dev/null)
        fi
        printf '%s\t%s\t%s\t%s\t%s' "$n" "$b" "$av" "$created" "$fc"
    else
        printf '\t\t\t\t'
    fi
    rm -f "$tmp"
}

_scrape_telegram() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 -A "$(_ua)" "https://t.me/s/${user}" -o "$tmp" 2>/dev/null
    if [[ ! -s "$tmp" ]]; then
        curl -sL --max-time 15 -A "$(_ua)" "https://t.me/${user}" -o "$tmp" 2>/dev/null
    fi
    local n b av fc
    n=$(grep -oP 'tgme_page_title[^>]*>\s*<span[^>]*>\K[^<]+' "$tmp" 2>/dev/null | head -n1)
    b=$(grep -oP 'tgme_page_description[^>]*>\K[^<]+' "$tmp" 2>/dev/null | head -n1 | sed 's/<[^>]*>//g')
    av=$(grep -oP 'tgme_page_photo_image[^>]*src="\K[^"]+' "$tmp" 2>/dev/null | head -n1)
    fc=$(grep -oP 'tgme_page_extra[^>]*>\K[^<]+' "$tmp" 2>/dev/null | head -n1)
    printf '%s\t%s\t%s\t\t%s' "$n" "$b" "$av" "$fc"
    rm -f "$tmp"
}

_scrape_snapchat() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 -A "$(_ua)" "https://www.snapchat.com/add/${user}" -o "$tmp" 2>/dev/null
    local n b av fc
    n=$(_meta_content_from_file "$tmp" "og:title")
    b=$(_meta_content_from_file "$tmp" "og:description")
    av=$(_meta_content_from_file "$tmp" "og:image")
    fc=$(grep -oP '"subscriberCount":\K[0-9]+' "$tmp" | head -n1)
    printf '%s\t%s\t%s\t\t%s' "$n" "$b" "$av" "$fc"
    rm -f "$tmp"
}

_scrape_pinterest() {
    local user="$1"
    local tmp; tmp="$(mktemp)"
    curl -sL --max-time 15 -A "$(_ua)" \
        -H "Accept: application/json" \
        -H "X-Requested-With: XMLHttpRequest" \
        "https://www.pinterest.com/resource/UserResource/get/?source_url=/user/${user}/&data=%7B%22options%22%3A%7B%22username%22%3A%22${user}%22%7D%7D" \
        -o "$tmp" 2>/dev/null
    if jq -e '.resource_response.data' "$tmp" >/dev/null 2>&1; then
        local n b av fc
        n=$(jq -r '.resource_response.data.full_name // .resource_response.data.username // empty' "$tmp")
        b=$(jq -r '.resource_response.data.about // empty' "$tmp")
        av=$(jq -r '.resource_response.data.image_xlarge_url // .resource_response.data.image_medium_url // empty' "$tmp")
        fc=$(jq -r '.resource_response.data.follower_count // empty' "$tmp")
        printf '%s\t%s\t%s\t\t%s' "$n" "$b" "$av" "$fc"
    else
        printf '\t\t\t\t'
    fi
    rm -f "$tmp"
}

_scrape_bilibili() {
    local user="$1"
    local tmp; tmp="$(mktemp)"

    local mid=""
    if [[ "$user" =~ ^[0-9]+$ ]]; then
        mid="$user"
    else
        local enc; enc=$(urlencode "$user")
        curl -s --max-time 15 -A "$(_ua)" \
            -H "Referer: https://www.bilibili.com/" \
            "https://api.bilibili.com/x/web-interface/search/type?search_type=bili_user&keyword=${enc}" \
            -o "$tmp" 2>/dev/null
        if jq -e . "$tmp" >/dev/null 2>&1; then
            mid=$(jq -r --arg u "$user" '
                .data.result[]?
                | select((.uname // "") | ascii_downcase == ($u | ascii_downcase))
                | .mid
            ' "$tmp" 2>/dev/null | head -n1)
        fi
    fi

    [[ -z "$mid" || "$mid" == "null" ]] && { printf '\t\t\t\t\t'; rm -f "$tmp"; return; }

    curl -s --max-time 15 -A "$(_ua)" \
        -H "Referer: https://www.bilibili.com/" \
        "https://api.bilibili.com/x/web-interface/card?mid=${mid}" \
        -o "$tmp" 2>/dev/null

    if jq -e '.data.card' "$tmp" >/dev/null 2>&1; then
        local n b av fc
        n=$(jq -r '.data.card.name // empty' "$tmp")
        b=$(jq -r '.data.card.sign // empty' "$tmp")
        av=$(jq -r '.data.card.face // empty' "$tmp")
        fc=$(jq -r '.data.follower // empty' "$tmp")
        printf '%s\t%s\t%s\t\t%s' "$n" "$b" "$av" "$fc"
    else
        printf '\t\t\t\t'
    fi
    rm -f "$tmp"
}

_scrape_roblox() {
    local user="$1"
    local tmp; tmp="$(mktemp)"

    curl -s --max-time 15 -X POST \
        -H "Content-Type: application/json" \
        -H "User-Agent: $(_ua)" \
        -d "{\"usernames\":[\"${user}\"],\"excludeBannedUsers\":false}" \
        "https://users.roblox.com/v1/usernames/users" \
        -o "$tmp" 2>/dev/null

    if ! jq -e '.data[0].id' "$tmp" >/dev/null 2>&1; then
        printf '\t\t\t\t'
        rm -f "$tmp"
        return
    fi

    local uid dn created
    uid=$(jq -r '.data[0].id // empty' "$tmp")
    dn=$(jq -r '.data[0].displayName // .data[0].name // empty' "$tmp")

    curl -s --max-time 15 -A "$(_ua)" \
        "https://users.roblox.com/v1/users/${uid}" -o "$tmp" 2>/dev/null
    if jq -e '.created' "$tmp" >/dev/null 2>&1; then
        dn=$(jq -r '.displayName // .name // empty' "$tmp")
        created=$(jq -r '.created // empty' "$tmp")
        [[ -n "$created" ]] && created=$(printf '%s' "$created" | cut -d'T' -f1)
    fi

    local av=""
    curl -s --max-time 15 -A "$(_ua)" \
        "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=${uid}&size=420x420&format=Png&isCircular=false" \
        -o "$tmp" 2>/dev/null
    if jq -e '.data[0].imageUrl' "$tmp" >/dev/null 2>&1; then
        av=$(jq -r '.data[0].imageUrl // empty' "$tmp")
    fi

    printf '%s\t\t%s\t%s\t' "$dn" "$av" "$created"
    rm -f "$tmp"
}

_scrape_profile_api() {
    local site="$1" user="$2"
    case "$site" in
        Instagram)     _scrape_instagram "$user" ;;
        "X (Twitter)") _scrape_twitter   "$user" ;;
        YouTube)       _scrape_youtube   "$user" ;;
        Facebook)      _scrape_facebook  "$user" ;;
        LinkedIn)      _scrape_linkedin  "$user" ;;
        Reddit)        _scrape_reddit    "$user" ;;
        Telegram)      _scrape_telegram  "$user" ;;
        Snapchat)      _scrape_snapchat  "$user" ;;
        Pinterest)     _scrape_pinterest "$user" ;;
        Bilibili)      _scrape_bilibili  "$user" ;;
        Roblox)        _scrape_roblox    "$user" ;;
        *)             printf '\t\t\t\t' ;;
    esac
}

_enrich_from_body() {
    local file="$1" site="$2" user="$3"
    [[ ! -s "$file" ]] && { printf '\t\t\t\t\t'; return; }

    local api_out
    api_out="$(_scrape_profile_api "$site" "$user")"
    IFS=$'\t' read -r api_name api_bio api_avatar api_joined api_followers <<< "$api_out"

    local og_name og_bio og_avatar
    og_name=$(_meta_content_from_file "$file" "og:title")
    og_bio=$(_meta_content_from_file "$file" "og:description")
    og_avatar=$(_meta_content_from_file "$file" "og:image")
    [[ -z "$og_name" ]]   && og_name=$(_meta_content_from_file "$file" "twitter:title")
    [[ -z "$og_bio" ]]    && og_bio=$(_meta_content_from_file "$file" "twitter:description")
    [[ -z "$og_avatar" ]] && og_avatar=$(_meta_content_from_file "$file" "twitter:image")

    local f_name="${api_name:-$og_name}"
    local f_bio="${api_bio:-$og_bio}"
    local f_avatar="${api_avatar:-$og_avatar}"
    local f_joined="${api_joined:-}"
    local f_followers="${api_followers:-}"

    case "$site" in
        GitHub)
            f_name=$(jq -r '.name // .login // empty' "$file" 2>/dev/null)
            f_bio=$(jq -r '.bio // empty' "$file" 2>/dev/null)
            f_avatar=$(jq -r '.avatar_url // empty' "$file" 2>/dev/null)
            f_joined=$(jq -r '.created_at // empty' "$file" 2>/dev/null)
            f_followers=$(jq -r '.followers // empty' "$file" 2>/dev/null)
            ;;
        Bluesky)
            f_name=$(jq -r '.handle // empty' "$file" 2>/dev/null)
            ;;
        Bilibili)
            f_name=$(jq -r '.data.card.name // empty' "$file" 2>/dev/null)
            f_bio=$(jq -r '.data.card.sign // empty' "$file" 2>/dev/null)
            f_avatar=$(jq -r '.data.card.face // empty' "$file" 2>/dev/null)
            f_followers=$(jq -r '.data.follower // empty' "$file" 2>/dev/null)
            ;;
        Weibo)
            f_name=$(grep -oP '"screen_name":"\K[^"]+' "$file" 2>/dev/null | head -n1)
            f_bio=$(grep -oP '"description":"\K[^"]+' "$file" 2>/dev/null | head -n1)
            f_followers=$(grep -oP '"followers_count":\K[0-9]+' "$file" 2>/dev/null | head -n1)
            ;;
    esac

    f_name=$(printf '%s' "$f_name" | tr '\t\n' '  ')
    f_bio=$(printf '%s' "$f_bio" | tr '\t\n' '  ')
    f_avatar=$(printf '%s' "$f_avatar" | tr '\t\n' '  ')
    f_joined=$(printf '%s' "$f_joined" | tr '\t\n' '  ')
    f_followers=$(printf '%s' "$f_followers" | tr '\t\n' '  ')

    printf '%s\t%s\t%s\t%s\t%s' \
        "${f_name:-}" "${f_bio:-}" "${f_avatar:-}" "${f_joined:-}" "${f_followers:-}"
}

_cross_fetch_full() {
    local url="$1"
    [[ -z "$url" ]] && { printf '000|0|0||||no|no|||||'; printf '\n/dev/null'; return; }
    local host; host=$(printf '%s' "$url" | awk -F/ '{print $3}')

    local hdr_file body_file cookie_jar
    hdr_file="$(mktemp -t tiktap.hdr.XXXXXX 2>/dev/null || mktemp)"
    body_file="$(mktemp -t tiktap.body.XXXXXX 2>/dev/null || mktemp)"
    cookie_jar="$(mktemp -t tiktap.jar.XXXXXX 2>/dev/null || mktemp)"

    local attempt=0 status=""
    while (( attempt <= CROSS_RETRY )); do
        status=$(curl -sL -A "$CROSS_UA" \
            -H "Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8" \
            -H "Accept-Language: en-US,en;q=0.9" \
            -H "Sec-Fetch-Dest: document" \
            -H "Sec-Fetch-Mode: navigate" \
            -H "Sec-Fetch-Site: none" \
            -H "Upgrade-Insecure-Requests: 1" \
            --compressed --max-time "$CROSS_TIMEOUT" \
            -c "$cookie_jar" -b "$cookie_jar" \
            -D "$hdr_file" -o "$body_file" \
            -w '%{http_code}|%{time_total}|%{num_redirects}|%{remote_ip}' \
            "$url" 2>/dev/null)

        if [[ "$status" == 200* && ! -s "$body_file" ]]; then
            status=$(curl -sL -A "$CROSS_UA" \
                -H "Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8" \
                -H "Accept-Language: en-US,en;q=0.9" \
                --max-time "$CROSS_TIMEOUT" \
                -c "$cookie_jar" -b "$cookie_jar" \
                -D "$hdr_file" -o "$body_file" \
                -w '%{http_code}|%{time_total}|%{num_redirects}|%{remote_ip}' \
                "$url" 2>/dev/null)
        fi

        [[ "$status" != 000* ]] && break
        (( attempt++ )); sleep "$attempt"
    done

    local http_code ttime redirs ip
    IFS='|' read -r http_code ttime redirs ip <<< "$status"

    if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
        CROSS_UA="$(pick_ua)"
        status=$(curl -sL -A "$CROSS_UA" \
            -H "Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8" \
            -H "Accept-Language: en-US,en;q=0.9" \
            --max-time "$CROSS_TIMEOUT" \
            -c "$cookie_jar" -b "$cookie_jar" \
            -D "$hdr_file" -o "$body_file" \
            -w '%{http_code}|%{time_total}|%{num_redirects}|%{remote_ip}' \
            "$url" 2>/dev/null)
        IFS='|' read -r http_code ttime redirs ip <<< "$status"
    fi

    if [[ -s "$body_file" ]]; then
        LC_ALL=C tr -d '\0' < "$body_file" > "${body_file}.clean" 2>/dev/null
        mv "${body_file}.clean" "$body_file"
    fi

    local srv powered hash spa ab
    srv=$(grep -i '^server:' "$hdr_file" | tail -n1 | cut -d' ' -f2- | tr -d '\r')
    powered=$(grep -i '^x-powered-by:' "$hdr_file" | tail -n1 | cut -d' ' -f2- | tr -d '\r')
    hash=$(head -c 200000 "$body_file" 2>/dev/null | _sha1)

    ab="no"
    if [[ -s "$body_file" ]]; then
        local body_size
        body_size=$(wc -c < "$body_file" 2>/dev/null || echo 0)
        local title_h1
        title_h1=$({
            grep -oP '<title[^>]*>\K[^<]+' "$body_file" 2>/dev/null | head -n1
            grep -oP '<h1[^>]*>\K[^<]+'    "$body_file" 2>/dev/null | head -n1
        })
        if printf '%s' "$title_h1" | grep -qiE '(just a moment|attention required|access denied|verifying you are human|checking your browser|enable javascript)'; then
            ab="yes"
        elif [[ "$http_code" == "403" || "$http_code" == "503" || "$http_code" == "429" ]]; then
            if grep -qiE '(cloudflare|datadome|perimeterx|px-captcha|hcaptcha)' "$body_file" 2>/dev/null; then
                ab="yes"
            fi
        elif (( body_size < 5120 )) && grep -qiF "captcha" "$body_file" 2>/dev/null; then
            ab="yes"
        fi
    fi

    spa="no"
    if [[ ! -s "$body_file" ]] || ! grep -q '<meta' "$body_file" 2>/dev/null; then spa="yes"; fi

    local dns_ip="disabled" dns_rev="disabled"
    if [[ "$CROSS_DNS" == "1" ]]; then
        local dns; dns=$(_dns_probe "$host"); dns_ip="${dns%%|*}"; dns_rev="${dns##*|}"
    fi
    local tls; tls=$(_tls_probe "$host")

    local chain
    chain=$(grep -i '^location:' "$hdr_file" | tr -d '\r' | awk '{print $2}' | paste -sd '>' -)

    srv=$(printf '%s' "$srv" | tr '\n' ' ')
    powered=$(printf '%s' "$powered" | tr '\n' ' ')
    chain=$(printf '%s' "$chain" | tr '\n' ' ')
    tls=$(printf '%s' "$tls" | tr '\n' ' ')
    dns_rev=$(printf '%s' "$dns_rev" | tr '\n' ' ')

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
        "$http_code" "$ttime" "$redirs" "$ip" \
        "${srv:-}" "${powered:-}" "$hash" "$spa" "$ab" \
        "$dns_ip" "$dns_rev" "$tls" "${chain:-}"
    printf '\n%s' "$body_file"
    rm -f "$hdr_file" "$cookie_jar"
}

_cross_verdict_v2() {
    local method="$1" http="$2" body_file="$3" ab="$4" ok_marker="$5" no_marker="$6" \
          status_ok="$7" status_no="$8"

    ok_marker=$(printf '%s' "$ok_marker" | sed 's/\\"/"/g')
    no_marker=$(printf '%s' "$no_marker" | sed 's/\\"/"/g')

    if [[ "$http" == "403" || "$http" == "429" ]]; then
        [[ "$ab" == "yes" ]] && { printf 'blocked|LOW|0|antibot'; return; }
        printf 'rate_limited|LOW|0|http_%s' "$http"; return
    fi
    [[ "$ab" == "yes" ]] && { printf 'blocked|LOW|0|antibot'; return; }
    [[ "$http" == "404" ]] && { printf 'not_found|HIGH|0|http_404'; return; }
    [[ -n "$status_no" && "$http" == "$status_no" ]] && { printf 'not_found|HIGH|0|http_no'; return; }

    if [[ "$method" == "status" ]]; then
        [[ -n "$status_ok" && "$http" == "$status_ok" ]] && { printf 'found|HIGH|80|http_ok'; return; }
        [[ "$http" == "200" ]] && { printf 'found|HIGH|70|http_200'; return; }
        [[ "$http" == "000" ]] && { printf 'unknown|LOW|0|no_response'; return; }
        printf 'unknown|LOW|0|status_%s' "$http"; return
    fi

    if [[ "$method" == "api" ]]; then
        [[ "$http" == "000" ]] && { printf 'unknown|LOW|0|no_response'; return; }
        if [[ "$http" =~ ^4 ]]; then
            printf 'not_found|HIGH|0|api_http_%s' "$http"; return
        fi
        if [[ "$http" == "200" && -s "$body_file" ]]; then
            if jq -e . "$body_file" >/dev/null 2>&1; then
                if [[ -n "$no_marker" ]] && grep -qF "$no_marker" "$body_file"; then
                    printf 'not_found|HIGH|0|api_not_ok'; return
                fi
                if [[ -n "$ok_marker" ]] && grep -qF "$ok_marker" "$body_file"; then
                    printf 'found|HIGH|90|api_key'; return
                fi
                if jq -e '.error or .errors or .message' "$body_file" >/dev/null 2>&1; then
                    printf 'maybe|MEDIUM|40|api_json_error'; return
                fi
                printf 'found|MEDIUM|60|api_200'; return
            fi
            [[ -n "$ok_marker" ]] && grep -qF "$ok_marker" "$body_file" \
                && { printf 'found|MEDIUM|70|body_ok'; return; }
            printf 'maybe|LOW|30|api_nonjson'; return
        fi
        printf 'unknown|LOW|0|api_http_%s' "$http"; return
    fi

    local title og_t og_d tw_t
    title=$(_page_title_from_file "$body_file")
    og_t=$(_meta_content_from_file "$body_file" "og:title")
    og_d=$(_meta_content_from_file "$body_file" "og:description")
    tw_t=$(_meta_content_from_file "$body_file" "twitter:title")

    if [[ "$method" == "tgme" ]]; then
        grep -qF 'tgme_page_title' "$body_file" 2>/dev/null \
            && { printf 'found|HIGH|90|tgme_title'; return; }
        grep -qF 'tgme_page_icon' "$body_file" 2>/dev/null \
            && { printf 'not_found|HIGH|0|tgme_icon'; return; }
        [[ "$http" == "200" ]] && { printf 'found|MEDIUM|50|tgme_200'; return; }
        printf 'unknown|LOW|10|tgme_neither'; return
    fi

    if [[ "$method" == "redirect" ]]; then
        [[ -n "$no_marker" ]] && grep -qiF "$no_marker" "$body_file" 2>/dev/null \
            && { printf 'not_found|HIGH|0|redir_not_ok'; return; }
        [[ -n "$ok_marker" ]] && grep -qF "$ok_marker" "$body_file" 2>/dev/null \
            && { printf 'found|HIGH|80|redir_ok'; return; }
        [[ "$http" == "200" ]] && { printf 'found|MEDIUM|50|redir_200'; return; }
        printf 'unknown|LOW|10|redir_%s' "$http"; return
    fi

    if [[ -n "$no_marker" ]]; then
        local content
        content=$({
            printf '%s\n' "$title" "$og_t" "$og_d" "$tw_t"
            sed -n '/<body/,/<\/body>/p' "$body_file" 2>/dev/null | tr -d '\n' | head -c 3000
        })
        if printf '%s' "$content" | grep -qiF "$no_marker"; then
            if [[ -z "$ok_marker" ]] || ! grep -qiF "$ok_marker" "$body_file" 2>/dev/null; then
                printf 'not_found|HIGH|0|content_not_ok'; return
            fi
        fi
    fi

    local ok_score=0
    if [[ -n "$ok_marker" && -s "$body_file" ]]; then
        if [[ "$ok_marker" == "og:title" || "$ok_marker" == "twitter:title" ]]; then
            local og_val
            og_val=$(_meta_content_from_file "$body_file" "$ok_marker")
            [[ -n "$og_val" ]] && ok_score=40
        else
            grep -qF "$ok_marker" "$body_file" 2>/dev/null && ok_score=40
        fi
    fi

    local og_score=0
    local og_lc; og_lc=$(printf '%s' "$og_t" | tr '[:upper:]' '[:lower:]')
    local generic_re='^(log in|login|sign up|sign in|not found|error|home|welcome|page not found|404|just a moment|instagram|facebook|tiktok|youtube|twitter|x|tumblr|bandcamp|kuaishou|last\.fm|soundcloud|mixcloud|medium|pinterest|twitch|reddit|spotify|snapchat|linkedin)$'
    if [[ -n "$og_t" && ! "$og_lc" =~ $generic_re ]]; then og_score=$((og_score + 30)); fi
    [[ -n "$og_d" ]] && og_score=$((og_score + 10))
    local t_lc; t_lc=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$title" && ! "$t_lc" =~ $generic_re ]]; then og_score=$((og_score + 20)); fi

    local total=$((ok_score + og_score))

    if (( total >= 60 )); then printf 'found|HIGH|%s|ok%s_og%s' "$total" "$ok_score" "$og_score"; return; fi
    if (( total >= 30 )); then printf 'found|MEDIUM|%s|ok%s_og%s' "$total" "$ok_score" "$og_score"; return; fi
    if (( total >= 10 )); then printf 'maybe|LOW|%s|ok%s_og%s' "$total" "$ok_score" "$og_score"; return; fi

    [[ "$http" == "200" ]] && { printf 'maybe|LOW|5|http_200_empty'; return; }
    printf 'not_found|LOW|0|no_signals'
}

_cross_worker_v2() {
    local idx="$1" user="$2" sites_file="$3" out_jsonl="$4"

    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
        printf 'ERROR\tworker\t000\tunknown\tLOW\t0\tbad-index\t0\t0\t\t\t\t\n'
        return
    fi
    if [[ ! -f "$sites_file" ]]; then
        printf 'ERROR\tworker\t000\tunknown\tLOW\t0\tno-sites\t0\t0\t\t\t\t\n'
        return
    fi

    local name url method ok no ok_status no_status
    name=$(jq -r ".[$idx].name"              "$sites_file" 2>/dev/null)
    url=$(jq -r  ".[$idx].url"               "$sites_file" 2>/dev/null)
    method=$(jq -r ".[$idx].method"          "$sites_file" 2>/dev/null)
    ok=$(jq -r     ".[$idx].ok     // \"\""  "$sites_file" 2>/dev/null)
    no=$(jq -r     ".[$idx].not_ok // \"\""  "$sites_file" 2>/dev/null)
    ok_status=$(jq -r  ".[$idx].ok_status  // \"\"" "$sites_file" 2>/dev/null)
    no_status=$(jq -r ".[$idx].not_status // \"\"" "$sites_file" 2>/dev/null)

    if [[ "$name" == "null" || -z "$name" ]]; then
        printf 'ERROR\tworker\t000\tunknown\tLOW\t0\tjq-null\t0\t0\t\t\t\t\n'
        return
    fi
    [[ "$method" == "null" || -z "$method" ]] && method="body"
    url="${url//\{u\}/$user}"

    local raw_full body_file raw_meta
    raw_full="$(_cross_fetch_full "$url")"
    body_file="$(printf '%s' "$raw_full" | tail -n1)"
    raw_meta="$(printf '%s' "$raw_full" | head -n1)"
    raw_meta=$(printf '%s' "$raw_meta" | tr '\n' ' ')

    IFS='|' read -r http ttime redirs ip srv powered hash spa ab dnsip dnsrev tls chain <<< "$raw_meta"
    [[ -z "$body_file" || ! -f "$body_file" ]] && body_file="/dev/null"

    local v
    v=$(_cross_verdict_v2 "$method" "$http" "$body_file" "$ab" "$ok" "$no" "$ok_status" "$no_status")
    IFS='|' read -r verdict conf score reason <<< "$v"

    local wb; wb=$(_wayback_probe "$url")
    IFS='|' read -r wb_ts wb_url <<< "$wb"

    local enrich
    enrich=$(_enrich_from_body "$body_file" "$name" "$user")
    IFS=$'\t' read -r e_name e_bio e_avatar e_joined e_followers <<< "$enrich"

    e_name=$(printf '%s' "$e_name" | tr '\t\n' '  ')
    e_joined=$(printf '%s' "$e_joined" | tr '\t\n' '  ')
    e_followers=$(printf '%s' "$e_followers" | tr '\t\n' '  ')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$url" "$http" "$verdict" "$conf" "$score" "$method" "$ttime" \
        "${redirs:-0}" "${ip:-}" "${e_name:-}" "${e_joined:-}" "${e_followers:-}"

    if [[ -n "$out_jsonl" ]]; then
        jq -nc \
            --arg name "$name" --arg url "$url" --arg http "$http" \
            --arg verdict "$verdict" --arg conf "$conf" --arg score "$score" \
            --arg method "$method" --arg ttime "$ttime" --arg redirs "$redirs" \
            --arg ip "$ip" --arg srv "$srv" --arg powered "$powered" \
            --arg hash "$hash" --arg spa "$spa" --arg ab "$ab" \
            --arg dnsip "$dnsip" --arg dnsrev "$dnsrev" --arg tls "$tls" \
            --arg chain "$chain" --arg ename "$e_name" --arg ebio "$e_bio" \
            --arg eavatar "$e_avatar" --arg ejoined "$e_joined" \
            --arg efollowers "$e_followers" \
            --arg wbts "$wb_ts" --arg wburl "$wb_url" --arg reason "$reason" \
            '{name:$name,url:$url,http:$http,verdict:$verdict,confidence:$conf,score:($score|tonumber),
              method:$method,response_time:$ttime,redirects:$redirs,remote_ip:$ip,
              server:$srv,x_powered_by:$powered,body_hash:$hash,spa_shell:$spa,antibot:$ab,
              dns_ip:$dnsip,dns_reverse:$dnsrev,tls:$tls,redirect_chain:$chain,
              profile_name:$ename,bio:$ebio,avatar:$eavatar,joined:$ejoined,followers:$efollowers,
              wayback_timestamp:$wbts,wayback_url:$wburl,reason:$reason}' >> "$out_jsonl"
    fi

    [[ "$body_file" != "/dev/null" ]] && rm -f "$body_file"
}

export -f _cross_worker_v2 _cross_fetch_full _cross_verdict_v2 _enrich_from_body \
          _meta_content_from_file _page_title_from_file _dns_probe _tls_probe \
          _wayback_probe _sha1 pick_ua _ua _scrape_profile_api \
          _scrape_instagram _scrape_twitter _scrape_youtube _scrape_facebook \
          _scrape_linkedin _scrape_reddit _scrape_telegram _scrape_snapchat \
          _scrape_pinterest _scrape_bilibili _scrape_roblox
export CROSS_UA CROSS_TIMEOUT CROSS_RETRY CROSS_WAYBACK CROSS_TLS CROSS_DNS UA_POOL

cross_check_username() {
    local user="$1"
    ensure_sites_file

    local total
    total=$(jq -r 'length' "$SITES_FILE" 2>/dev/null)
    if [[ -z "$total" || "$total" == "null" || "$total" -lt 1 ]]; then
        row "Cross-site" "sites.json empty or invalid" "$c_dgrey"
        return
    fi

    row "Platforms Checked" "$total"             "$c_white"
    row "Concurrency"       "$CROSS_CONCURRENCY" "$c_white"
    row "Timeout"           "${CROSS_TIMEOUT}s"  "$c_white"
    row "Wayback Lookup"    "$([[ "$CROSS_WAYBACK" == "1" ]] && echo yes || echo no)" "$c_white"
    row "TLS Fingerprint"   "$([[ "$CROSS_TLS" == "1" ]] && echo yes || echo no)"     "$c_white"
    row "DNS Probe"         "$([[ "$CROSS_DNS" == "1" ]] && echo yes || echo no)"     "$c_white"
    row "API Scrapers"      "yes"                 "$c_white"
    divider

    : > "$CROSS_REPORT_TSV"
    : > "$CROSS_REPORT_JSONL"
    : > "$CROSS_REPORT_ERR"

    if command -v xargs >/dev/null 2>&1; then
        seq 0 $((total-1)) \
            | xargs -n 1 -P "$CROSS_CONCURRENCY" -I IDX \
                bash -c '_cross_worker_v2 "$@"' _ IDX "$user" "$SITES_FILE" "$CROSS_REPORT_JSONL" \
                >> "$CROSS_REPORT_TSV" 2>> "$CROSS_REPORT_ERR"
    else
        local i=0
        while (( i < total )); do
            _cross_worker_v2 "$i" "$user" "$SITES_FILE" "$CROSS_REPORT_JSONL" >> "$CROSS_REPORT_TSV"
            (( i++ ))
        done
    fi

    if [[ ! -s "$CROSS_REPORT_TSV" ]]; then
        row "ERROR" "no worker output — see $CROSS_REPORT_ERR" "$c_red"
        return
    fi

    awk -F'\t' '
        function pri(v){
            if(v=="found")return 1;
            if(v=="maybe")return 2;
            if(v=="rate_limited")return 3;
            if(v=="blocked")return 4;
            if(v=="not_found")return 5;
            return 6
        }
        { print pri($4)"\t" (100-$6) "\t" $0 }
    ' "$CROSS_REPORT_TSV" | sort -k1,1n -k2,2n | cut -f3- > "${CROSS_REPORT_TSV}.sorted"
    mv "${CROSS_REPORT_TSV}.sorted" "$CROSS_REPORT_TSV"

    local found=0 maybe=0 blocked=0 notfound=0 unknown=0 ratelimited=0
    while IFS=$'\t' read -r name url http verdict conf score method ttime redirs ip pname joined followers; do
        [[ -z "$name" ]] && continue
        case "$verdict" in
            found)
                ((found++))
                local extra=""
                [[ -n "$pname" ]]     && extra+="  name:$pname"
                [[ -n "$joined" ]]    && extra+="  since:$joined"
                [[ -n "$followers" ]] && extra+="  followers:$followers"
                row "$name" "FOUND [$conf/$score] ${ttime}s$extra" "$c_green"
                ;;
            maybe)
                ((maybe++))
                row "$name" "maybe [$conf/$score]" "$c_ice"
                ;;
            blocked)
                ((blocked++))
                row "$name" "blocked (anti-bot)" "$c_yellow"
                ;;
            rate_limited)
                ((ratelimited++))
                row "$name" "rate-limited [HTTP $http]" "$c_orange"
                ;;
            not_found)
                ((notfound++))
                row "$name" "not found" "$c_dgrey"
                ;;
            *)
                ((unknown++))
                row "$name" "unknown [HTTP $http]" "$c_red"
                ;;
        esac
    done < "$CROSS_REPORT_TSV"

    divider
    row "FOUND"        "$found"        "$c_green"
    row "Maybe"        "$maybe"        "$c_ice"
    row "Blocked"      "$blocked"      "$c_yellow"
    row "Rate-limited" "$ratelimited"  "$c_orange"
    row "Not found"    "$notfound"     "$c_dgrey"
    row "Unknown"      "$unknown"      "$c_red"
    divider
    row "TSV Report"   "$CROSS_REPORT_TSV"   "$c_ice"
    row "JSONL Report" "$CROSS_REPORT_JSONL" "$c_ice"
}

build_dorks() {
    local u="$1"
    cat <<EOF
site:instagram.com "$u"
site:x.com "$u"
site:twitter.com "$u"
site:facebook.com "$u"
site:linkedin.com "$u"
site:github.com "$u"
site:reddit.com "$u"
site:medium.com "$u"
site:youtube.com "$u"
site:pinterest.com "$u"
site:tumblr.com "$u"
site:likee.video "$u"
site:bigo.tv "$u"
site:kwai.com "$u"
"$u" bio
"$u" biodata
"$u" "about me"
"$u" comment
"$u" "commented on"
"$u" likes
"$u" tagged
"$u" mention
"$u" "mentioned in"
"$u" profile
"$u" resume
"$u" CV
"$u" email
"$u" contact
"$u" phone
"$u" address
"$u" location
"$u" birthday
"$u" "born on"
"$u" anniversary
"$u" joined
"$u" "member since"
"$u" "created on"
"$u" "last updated"
"$u" "last modified"
"$u" filetype:pdf
"$u" filetype:doc OR filetype:docx
"$u" filetype:xls OR filetype:xlsx
"$u" filetype:ppt OR filetype:pptx
"$u" filetype:txt
"$u" filetype:log
"$u" filetype:sql
"$u" filetype:json
"$u" filetype:xml
"$u" filetype:csv
"$u" inurl:profile
"$u" inurl:user
"$u" inurl:account
"$u" inurl:bio
"$u" intitle:"$u"
"$u" -site:tiktok.com
"$u" pastebin
"$u" "data leak"
"$u" leak
EOF
}

run_dork_engine() {
    local q="$1"
    local enc
    enc=$(urlencode "$q")
    local url=""
    case "$DORK_ENGINE" in
        duckduckgo) url="https://html.duckduckgo.com/html/?q=${enc}" ;;
        bing)       url="https://www.bing.com/search?q=${enc}" ;;
        google)     url="https://www.google.com/search?q=${enc}&num=${DORK_MAX_RESULTS}" ;;
        *)          url="https://html.duckduckgo.com/html/?q=${enc}" ;;
    esac

    local html
    html="$(curl -sL -A "$CROSS_UA" \
            -H "Accept-Language: en-US,en;q=0.9" \
            --compressed --max-time "$DORK_TIMEOUT" "$url" 2>/dev/null | LC_ALL=C tr -d '\0')"

    case "$DORK_ENGINE" in
        duckduckgo)
            printf '%s' "$html" | grep -oP 'result__a[^>]*href="\K[^"]+' | head -n "$DORK_MAX_RESULTS"
            ;;
        bing)
            printf '%s' "$html" | grep -oP '<h2><a href="\K[^"]+' | head -n "$DORK_MAX_RESULTS"
            ;;
        google)
            printf '%s' "$html" | grep -oP '/url\?q=\K[^&]+' | head -n "$DORK_MAX_RESULTS"
            ;;
    esac
}

dork_module() {
    local user="$1"
    local DORKS=()
    while IFS= read -r line; do DORKS+=("$line"); done < <(build_dorks "$user")

    row "Engine"          "$DORK_ENGINE"        "$c_cyan"
    row "Dorks Generated" "${#DORKS[@]}"        "$c_white"
    row "Fetch Enabled"   "$([[ "$DORK_FETCH" == "1" ]] && echo yes || echo no)" "$c_white"
    divider

    local i=0
    while (( i < ${#DORKS[@]} )); do
        local q="${DORKS[$i]}"
        printf '%s|%s ' "$c_deep" "$nc"
        printf '%s[dork %02d]%s %s%s%s\n' \
            "$c_magenta$bold" "$((i+1))" "$nc" "$c_ice" "$q" "$nc"

        if [[ "$DORK_FETCH" == "1" ]]; then
            local results
            results="$(run_dork_engine "$q")"
            if [[ -z "$results" ]]; then
                printf '%s|%s   %s(no results / blocked)%s\n' "$c_deep" "$nc" "$c_dgrey" "$nc"
            else
                while IFS= read -r link; do
                    [[ -z "$link" ]] && continue
                    printf '%s|%s   %s->%s %s%s%s\n' \
                        "$c_deep" "$nc" "$c_green" "$nc" "$c_white" "$link" "$nc"
                done <<< "$results"
            fi
            sleep "$DORK_SLEEP"
        fi
        (( i++ ))
    done
}

save_raw() {
    local user="$1"
    local fname="${user}.txt"

    {
        printf '============================================================\n'
        printf ' TikTap - TikTok Scraper & Username Reconnaissance\n'
        printf ' Author : SYLHETYHACKVENGER (THE-ERROR808)\n'
        printf ' GitHub : sylhetyhackvenger\n'
        printf ' Target : @%s\n' "$user"
        printf ' Date   : %s\n' "$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        printf '============================================================\n\n'

        printf '[ PROFILE ]\n'
        printf 'User ID               : %s\n' "${id:-N/A}"
        printf 'Username              : @%s\n' "${uniqueId:-N/A}"
        printf 'Nickname              : %s\n' "${nickname:-N/A}"
        printf 'Verified              : %s\n' "$(bool_str "$secret")"
        printf 'Private               : %s\n' "$(bool_str "$privateAccount")"
        printf 'TikTok Seller         : %s\n' "$(bool_str "$ttSeller")"
        printf 'FTC User              : %s\n' "$(bool_str "$ftcUser")"
        printf 'Language              : %s\n' "${language:-N/A}"
        printf 'Region                : %s\n' "${region:-N/A}"
        printf 'SecUid                : %s\n' "${secUid:-N/A}"
        printf 'Bio Link              : %s\n' "${bioLink:-N/A}"
        printf 'Room ID               : %s\n' "${roomId:-N/A}"
        printf 'Commerce User Info    : %s\n' "${commerceUser:-N/A}"
        printf '\n'

        printf '[ STATS ]\n'
        printf 'Followers             : %s (%s)\n' "${followerCount:-0}" "$(pretty_num "$followerCount")"
        printf 'Following             : %s (%s)\n' "${followingCount:-0}" "$(pretty_num "$followingCount")"
        printf 'Likes                 : %s (%s)\n' "${heartCount:-0}" "$(pretty_num "$heartCount")"
        printf 'Videos                : %s (%s)\n' "${videoCount:-0}" "$(pretty_num "$videoCount")"
        printf 'Friends               : %s\n' "${friendCount:-0}"
        printf 'Digg Count            : %s\n' "${diggCount:-0}"
        printf '\n'

        printf '[ TIMELINE ]\n'
        printf 'Account Created       : %s\n' "${createTime_h:-N/A}"
        printf 'Username Changed      : %s\n' "${uniqueIdModifyTime_h:-N/A}"
        printf 'Nickname Changed      : %s\n' "${nickNameModifyTime_h:-N/A}"
        printf 'Bio Changed           : %s\n' "${signatureModifyTime_h:-N/A}"
        printf 'Avatar Changed        : %s\n' "${avatarModifyTime_h:-N/A}"
        printf '\n'

        printf '[ BIOGRAPHY ]\n'
        printf '%s\n' "${signature:-N/A}"
        printf '\n'

        printf '[ PRIVACY AND SETTINGS ]\n'
        printf 'Comment Setting       : %s\n' "${commentSetting:-N/A}"
        printf 'Duet Setting          : %s\n' "${duetSetting:-N/A}"
        printf 'Stitch Setting        : %s\n' "${stitchSetting:-N/A}"
        printf 'Open Favorite         : %s\n' "$(bool_str "$openFavorite")"
        printf 'AD Virtual            : %s\n' "$(bool_str "$isADVirtual")"
        printf 'Embed Banned          : %s\n' "$(bool_str "$isEmbedBanned")"
        printf '\n'

        printf '[ OBFUSCATED CREDENTIALS ]\n'
        printf 'csrfToken             : %s\n' "${csrf_token:-N/A}"
        printf '_signature            : %s\n' "${_signature:-N/A}"
        printf 'verifyFp              : %s\n' "${verifyFp_html:-N/A}"
        printf 'odnFp                 : %s\n' "${odnFp_html:-N/A}"
        printf '\n'

        printf '[ SESSION COOKIES ]\n'
        printf 'ttwid                 : %s\n' "${ttwid:-N/A}"
        printf 'tt_webid              : %s\n' "${tt_webid:-N/A}"
        printf 's_v_web_id            : %s\n' "${s_v_web_id:-N/A}"
        printf 'msToken               : %s\n' "${msToken_cookie:-N/A}"
        printf 'webid                 : %s\n' "${webid_cookie:-N/A}"
        printf 'sessionid             : %s\n' "${sessionid_cookie:-N/A}"
        printf 'sessionid_ss          : %s\n' "${sessionid_ss_cookie:-N/A}"
        printf 'sid_tt                : %s\n' "${sid_tt_cookie:-N/A}"
        printf 'uid_tt                : %s\n' "${uid_tt_cookie:-N/A}"
        printf 'uid_tt_ss             : %s\n' "${uid_tt_ss_cookie:-N/A}"
        printf 'sid_guard             : %s\n' "${sid_guard_cookie:-N/A}"
        printf 'passport_csrf_token   : %s\n' "${passport_csrf_cookie:-N/A}"
        printf 'csrf_session_id       : %s\n' "${csrf_session_cookie:-N/A}"
        printf '\n'

        printf '[ JS BUNDLE AND SDK ]\n'
        printf 'webmssdkVersion       : %s\n' "${webmssdk_version:-N/A}"
        printf 'webapp.version        : %s\n' "${webapp_version:-N/A}"
        printf 'webapp.obfuscated     : %s\n' "${webapp_obfuscated:-N/A}"
        printf 'webmssdk.js URL       : %s\n' "${webmssdk_url:-N/A}"
        printf 'webapp.js URL         : %s\n' "${webapp_url:-N/A}"
        printf '\n'

        printf '[ RESPONSE HEADERS ]\n'
        printf 'server                : %s\n' "${server_hdr:-N/A}"
        printf 'date                  : %s\n' "${date_hdr:-N/A}"
        printf 'content-type          : %s\n' "${content_type:-N/A}"
        printf 'x-tt-logid            : %s\n' "${x_tt_logid:-N/A}"
        printf 'x-tt-trace-id         : %s\n' "${x_tt_trace:-N/A}"
        printf 'x-tt-timing           : %s\n' "${x_tt_timing:-N/A}"
        printf 'x-tt-region           : %s\n' "${x_tt_region:-N/A}"
        printf '\n'

        printf '[ AVATARS ]\n'
        printf 'avatarLarger          : %s\n' "${avatarLarger:-N/A}"
        printf 'avatarMedium          : %s\n' "${avatarMedium:-N/A}"
        printf 'avatarThumb           : %s\n' "${avatarThumb:-N/A}"
        printf '\n'

        printf '[ RECENT POSTS ]\n'
        if [[ -n "$posts_json" ]] && [[ "$(printf '%s' "$posts_json" | jq -r '.statusCode // empty' 2>/dev/null)" == "0" ]]; then
            printf '%s' "$posts_json" | jq -r '.itemList[]? |
                "---\nID          : \(.id // "N/A")\nCaption     : \(.desc // "")\nViews       : \(.stats.playCount // 0)\nLikes       : \(.stats.diggCount // 0)\nComments    : \(.stats.commentCount // 0)\nShares      : \(.stats.shareCount // 0)\nSaves       : \(.stats.collectCount // 0)\nDuration(ms): \(.video.duration // 0)\nCreatedUnix : \(.createTime // 0)\n"' 2>/dev/null
        else
            printf '(not retrieved)\n'
        fi
        printf '\n'

        printf '[ FOLLOWERS ]\n'
        if [[ -n "$followers_json" ]] && [[ "$(printf '%s' "$followers_json" | jq -r '.statusCode // empty' 2>/dev/null)" == "0" ]]; then
            printf '%s' "$followers_json" | jq -r '.userList[]? |
                "---\nUsername : @\(.user.uniqueId // "N/A")\nNickname : \(.user.nickname // "N/A")\nVerified : \(.user.verified // false)\nBio      : \(.user.signature // "")\n"' 2>/dev/null
        else
            printf '(not retrieved)\n'
        fi
        printf '\n'

        printf '[ FOLLOWING ]\n'
        if [[ -n "$following_json" ]] && [[ "$(printf '%s' "$following_json" | jq -r '.statusCode // empty' 2>/dev/null)" == "0" ]]; then
            printf '%s' "$following_json" | jq -r '.userList[]? |
                "---\nUsername : @\(.user.uniqueId // "N/A")\nNickname : \(.user.nickname // "N/A")\nVerified : \(.user.verified // false)\nBio      : \(.user.signature // "")\n"' 2>/dev/null
        else
            printf '(not retrieved)\n'
        fi
        printf '\n'

        printf '[ COMMENTS ON LATEST POST ]\n'
        if [[ -n "$comments_json" ]] && [[ "$(printf '%s' "$comments_json" | jq -r '.statusCode // empty' 2>/dev/null)" == "0" ]]; then
            printf '%s' "$comments_json" | jq -r '.comments[]? |
                "---\nUser  : @\(.user.uniqueId // "N/A")\nLikes : \(.digg_count // 0)\nText  : \(.text // "")\n"' 2>/dev/null
        else
            printf '(not retrieved)\n'
        fi
        printf '\n'

        printf '[ CROSS-SITE PROFILE ENRICHMENT ]\n'
        if [[ -s "$CROSS_REPORT_TSV" ]]; then
            printf '%-20s %-6s %-12s %-6s %-6s %-24s %-12s %s\n' \
                'NAME' 'HTTP' 'VERDICT' 'CONF' 'SCORE' 'PROFILE_NAME' 'JOINED' 'FOLLOWERS'
            while IFS=$'\t' read -r name url http verdict conf score method ttime redirs ip pname joined followers; do
                printf '%-20s %-6s %-12s %-6s %-6s %-24s %-12s %s\n' \
                    "$name" "$http" "$verdict" "$conf" "$score" \
                    "${pname:--}" "${joined:--}" "${followers:--}"
            done < "$CROSS_REPORT_TSV"
        else
            printf '(no report)\n'
        fi
        printf '\n'

        printf '[ CROSS-SITE JSONL ]\n'
        if [[ -s "$CROSS_REPORT_JSONL" ]]; then
            cat "$CROSS_REPORT_JSONL"
        else
            printf '(no report)\n'
        fi
        printf '\n'

        printf '[ DORKS ]\n'
        while IFS= read -r d; do
            printf '%s\n' "$d"
        done < <(build_dorks "$user")
        printf '\n'

        printf '[ LINKS ]\n'
        printf 'TikTok                : https://tiktok.com/@%s\n' "${uniqueId:-}"
    } > "$fname"

    printf '%s' "$fname"
}

ask_save() {
    local user="$1"
    printf '\n'
    printf '  %s%s+-[ %sSAVE RAW DATA%s ]%s\n' "$c_deep" "$bold" "$c_magenta" "$nc$c_deep" "$nc"
    printf '  %s|%s\n' "$c_deep" "$nc"
    printf '  %s|%s  %sSave gathered information as%s %s%s.txt%s %s?%s\n' \
        "$c_deep" "$nc" "$c_ice" "$nc" "$c_yellow$bold" "$user" "$nc" "$c_white" "$nc"
    printf '  %s|%s  %s[y]%s yes   %s[n]%s no\n' \
        "$c_deep" "$nc" "$c_green$bold" "$nc" "$c_red$bold" "$nc"
    printf '  %s|%s  %s> %s' "$c_deep" "$nc" "$c_cyan" "$nc"
    read -r answer
    printf '  %s+--------------------------------------------------%s\n' "$c_deep" "$nc"

    case "${answer,,}" in
        y|yes)
            local saved
            saved="$(save_raw "$user")"
            printf '\n  %s%s[OK] saved%s -> %s%s%s\n\n' \
                "$c_green" "$bold" "$nc" "$c_cyan$underline" "$saved" "$nc"
            ;;
        *)
            printf '\n  %s%s[--] skipped%s - no file written\n\n' \
                "$c_yellow" "$bold" "$nc"
            ;;
    esac
}

render() {
    printf '\n'
    top_border

    section "PROFILE" "$c_magenta"
    row "User ID"        "${id:-N/A}"                              "$c_white"
    row "Username"       "@${uniqueId:-N/A}"                       "$c_green"
    row "Nickname"       "${nickname:-N/A}"                        "$c_white"
    row "Verified"       "$(bool_str "$secret")"                   "$c_cyan"
    row "Private"        "$(bool_str "$privateAccount")"           "$c_cyan"
    row "TikTok Seller"  "$(bool_str "$ttSeller")"                 "$c_cyan"
    row "FTC User"       "$(bool_str "$ftcUser")"                  "$c_cyan"
    row "Language"       "${language:-N/A}"                        "$c_white"
    row "Region"         "${region:-N/A}"                          "$c_white"
    row "SecUid"         "${secUid:-N/A}"                          "$c_dgrey"
    row "Bio Link"       "${bioLink:-N/A}"                         "$c_ice"
    row "Room ID"        "${roomId:-N/A}"                          "$c_ice"
    row "Commerce Info"  "${commerceUser:-N/A}"                    "$c_dgrey"
    divider

    section "STATS" "$c_lime"
    row "Followers"  "${followerCount:-0}  ($(pretty_num "$followerCount"))"    "$c_magenta"
    row "Following"  "${followingCount:-0}  ($(pretty_num "$followingCount"))"  "$c_cyan"
    row "Likes"      "${heartCount:-0}  ($(pretty_num "$heartCount"))"          "$c_pink"
    row "Videos"     "${videoCount:-0}  ($(pretty_num "$videoCount"))"          "$c_cyan"
    row "Friends"    "${friendCount:-0}"                                        "$c_white"
    row "Digg Count" "${diggCount:-0}"                                          "$c_yellow"
    row "Heart"      "${heartCount:-0}"                                         "$c_pink"
    divider

    section "TIMELINE" "$c_gold"
    row "Account Created"      "${createTime_h:-N/A}"           "$c_white"
    row "Username Changed"     "${uniqueIdModifyTime_h:-N/A}"   "$c_white"
    row "Nickname Changed"     "${nickNameModifyTime_h:-N/A}"   "$c_white"
    row "Bio Changed"          "${signatureModifyTime_h:-N/A}"  "$c_white"
    row "Avatar Changed"       "${avatarModifyTime_h:-N/A}"     "$c_white"
    divider

    section "BIOGRAPHY" "$c_pink"
    para "$signature" "$c_ice"
    divider

    section "PRIVACY AND SETTINGS" "$c_purple"
    row "Comment Setting"  "${commentSetting:-N/A}"              "$c_white"
    row "Duet Setting"     "${duetSetting:-N/A}"                 "$c_white"
    row "Stitch Setting"   "${stitchSetting:-N/A}"               "$c_white"
    row "Open Favorite"    "$(bool_str "$openFavorite")"         "$c_cyan"
    row "AD Virtual"       "$(bool_str "$isADVirtual")"          "$c_cyan"
    row "Embed Banned"     "$(bool_str "$isEmbedBanned")"        "$c_cyan"
    divider

    section "RECENT POSTS (${MAX_POSTS} MAX)" "$c_lime"
    render_posts
    divider

    section "FOLLOWERS (${MAX_FOLLOWERS} MAX)" "$c_green"
    render_userlist "Followers" "$followers_json"
    divider

    section "FOLLOWING (${MAX_FOLLOWING} MAX)" "$c_blue"
    render_userlist "Following" "$following_json"
    divider

    section "COMMENTS ON LATEST POST" "$c_pink"
    render_comments
    divider

    section "OBFUSCATED CREDENTIALS" "$c_crimson"
    row "csrfToken"          "${csrf_token:-N/A}"          "$c_yellow"
    row "_signature"         "${_signature:-N/A}"          "$c_yellow"
    row "verifyFp"           "${verifyFp_html:-N/A}"       "$c_yellow"
    row "odnFp"              "${odnFp_html:-N/A}"          "$c_yellow"
    divider

    section "SESSION COOKIES" "$c_orange"
    row "ttwid"               "${ttwid:-N/A}"               "$c_ice"
    row "tt_webid"            "${tt_webid:-N/A}"            "$c_ice"
    row "s_v_web_id"          "${s_v_web_id:-N/A}"          "$c_ice"
    row "msToken"             "${msToken_cookie:-N/A}"      "$c_ice"
    row "webid"               "${webid_cookie:-N/A}"        "$c_ice"
    row "sessionid"           "${sessionid_cookie:-N/A}"    "$c_ice"
    row "sessionid_ss"        "${sessionid_ss_cookie:-N/A}" "$c_ice"
    row "sid_tt"              "${sid_tt_cookie:-N/A}"       "$c_ice"
    row "uid_tt"              "${uid_tt_cookie:-N/A}"       "$c_ice"
    row "uid_tt_ss"           "${uid_tt_ss_cookie:-N/A}"    "$c_ice"
    row "sid_guard"           "${sid_guard_cookie:-N/A}"    "$c_ice"
    row "passport_csrf_token" "${passport_csrf_cookie:-N/A}" "$c_ice"
    row "csrf_session_id"     "${csrf_session_cookie:-N/A}" "$c_ice"
    divider

    section "JS BUNDLE AND SDK" "$c_blue"
    row "webmssdkVersion"    "${webmssdk_version:-N/A}"    "$c_white"
    row "webapp.version"     "${webapp_version:-N/A}"      "$c_white"
    row "webapp.obfuscated"  "${webapp_obfuscated:-N/A}"   "$c_white"
    row "webmssdk.js URL"    "${webmssdk_url:-N/A}"        "$c_dgrey"
    row "webapp.js URL"      "${webapp_url:-N/A}"          "$c_dgrey"
    divider

    section "RESPONSE HEADERS" "$c_cyan"
    row "server"        "${server_hdr:-N/A}"       "$c_white"
    row "date"          "${date_hdr:-N/A}"         "$c_white"
    row "content-type"  "${content_type:-N/A}"     "$c_white"
    row "x-tt-logid"    "${x_tt_logid:-N/A}"       "$c_dgrey"
    row "x-tt-trace-id" "${x_tt_trace:-N/A}"       "$c_dgrey"
    row "x-tt-timing"   "${x_tt_timing:-N/A}"      "$c_dgrey"
    row "x-tt-region"   "${x_tt_region:-N/A}"      "$c_dgrey"
    divider

    section "CROSS-SITE USERNAME RECON" "$c_purple"
    cross_check_username "${uniqueId:-$username}"
    divider

    section "INTERNET FOOTPRINT DORKS" "$c_orange"
    dork_module "${uniqueId:-$username}"
    divider

    section "LINKS" "$c_green"
    row "TikTok"   "https://tiktok.com/@${uniqueId:-}"   "$c_cyan"
    row "Avatar"   "${avatarLarger:-N/A}"                "$c_dgrey"
    bottom_border
    printf '\n'
}

render_error() {
    printf '\n'
    top_border
    section "ERROR" "$c_red"
    row "Status"  "Target profile not found"                     "$c_red"
    row "Reason"  "TikTok may be blocking, or username does not exist" "$c_red"
    row "Hint"    "Wait a few seconds and try a different username"    "$c_yellow"
    bottom_border
    printf '\n'
}

main() {
    banner
    ensure_sites_file

    username=""
    if [[ -n "${1:-}" ]]; then
        username="${1//@/}"
    else
        prompt_user
    fi

    if [[ -z "$username" ]]; then
        printf '  %s%s[x] no username provided%s\n\n' "$c_red" "$bold" "$nc"
        exit 1
    fi

    printf '  %s%s[*] scanning%s %s@%s%s %s...%s' "$c_mid" "$bold" "$nc" "$c_green" "$username" "$nc" "$c_grey" "$nc"
    for _ in 1 2 3; do printf '.'; sleep 0.35; done
    printf '\r%*s\r' "$TERM_WIDTH" ""

    if fetch_and_parse "$username"; then
        render
        ask_save "$username"
    else
        render_error
        exit 1
    fi
}

main "$@"
