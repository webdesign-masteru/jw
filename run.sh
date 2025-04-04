#!/bin/bash

set -e # Exit on error

# Configuration variables
output_dir="dist/"
deploy_server="user@server.com:path/to/public_html/"
rsync_options="-avz --delete --delete-excluded --include=*.htaccess"
jekyll_config="_config.yml,_config_dev.yml"
js_sources="src/scripts/*.js"
js_output_dir="src/scripts/dist/"
preview_host="192.168.1.126"
preview_port="3000"
compression_options="-t7z -mx=9 -m0=LZMA2 -mmt=on"
enable_start=0

# Core commands
run_dev() {
  check_deps "jekyll" "esbuild"
  trap run_clean INT
  jekyll serve --host 0.0.0.0 --watch --force_polling --livereload --incremental --config "$jekyll_config" &
  esbuild "$js_sources" --bundle --outdir="$js_output_dir" --minify --watch
  wait
}
run_build() {
  check_deps "jekyll" "esbuild"
  build_js
  build_jekyll
}
run_backup() {
  check_deps "7z"
  jekyll clean
  local dir_name="$(basename "$(pwd)")"
  local current_date=$(date +%d-%m-%Y)
  7z a $compression_options -x!"$dir_name/dist" -x!"$dir_name/node_modules" "./$dir_name-$current_date.7z" "$(pwd)"
}
run_deploy() {
  check_deps "jekyll" "esbuild" "rsync"
  trap run_clean INT
  jekyll clean
  build_js
  build_jekyll
  rsync $rsync_options "$output_dir" "$deploy_server" || { echo "Deploy failed: rsync error"; exit 1; }
  jekyll clean
}
run_preview() {
  check_deps "jekyll"
  trap run_clean INT
  jekyll serve --watch --host "$preview_host" --port "$preview_port"
}
run_watch() {
  check_deps "esbuild" "jekyll"
  trap run_clean INT
  jekyll build --watch --force_polling &
  esbuild "$js_sources" --bundle --outdir="$js_output_dir" --minify --watch
  wait
}
run_clean() {
  check_deps "jekyll"
  jekyll clean
}

# Build-related functions
build_js() {
  esbuild "$js_sources" --bundle --outdir="$js_output_dir" --minify
}
build_jekyll() {
  jekyll build
}

# Docker commands
run_up() {
  check_deps "docker-compose"
  sudo chmod -R 777 .
  docker-compose up -d
}
run_down() {
  check_deps "docker-compose"
  docker-compose down
}
run_bash() {
  check_deps "docker-compose"
  docker-compose exec jekyll bash
}
run_prune() {
  check_deps "docker"
  docker system prune -af --volumes
}

# Main function
main() {
  local cmds=($(declare -F | awk '{print $3}' | grep '^run_'))
  local cmd_list=("${cmds[@]#run_}")
  local cmd="$1" usage="Usage: $0 {"
  [[ -z "$cmd" || ! " ${cmd_list[*]} " =~ " $cmd " ]] && {
    for c in "${cmd_list[@]}"; do usage+=" $c |"; done
    echo "${usage%|} }" >&2
    exit 1
  }
  "run_$cmd"
}

# Check dependencies
check_deps() {
  local deps=("$@")
  local missing=()
  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done
  if [ ${#missing[@]} -ne 0 ]; then
    echo "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# Function to start new project with Starter
run_start() {
  check_deps "git"

  starter_repo="https://github.com/webdesign-masteru/starter"
  starter_dir="src"

  case "$(uname -s)" in
    Darwin) # macOS
      SED="sed -E -i ''"
      ;;
    Linux|CYGWIN*|MINGW*|MSYS*) # Linux / Windows
      SED="sed -E -i"
      ;;
    *)
      SED="sed -E -i"
      ;;
  esac

  [ "$enable_start" -eq 0 ] && { echo "Command 'start' is disabled in ./run.sh"; exit 1; }

  read -rp "Are you sure you want to run 'start'? yes/no " response
  [[ $response != "yes" ]] && { echo "Operation canceled."; exit 0; }

  echo "Cloning starter project to temporary directory..."
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT
  git clone "$starter_repo" "$tmp_dir" || { echo "Failed to clone repository"; exit 1; }

  files_to_remove=(
    "$tmp_dir/trunk"
    "$tmp_dir/.gitignore"
    "$tmp_dir/.git"
    "$tmp_dir/readme.md"
    "$starter_dir/assets/images/favicon.ico"
  )
  rm -rf "${files_to_remove[@]}"

  styles_dir=$tmp_dir/styles
  if [[ -d $styles_dir ]]; then
    for file in "$styles_dir"/*.css; do
      [ -f "$file" ] || continue
      filename=$(basename "$file" .css)
      mv "$file" "$styles_dir/$([ "$filename" = "index" ] && echo "index.scss" || echo "_$filename.css")"
    done
  fi

  process_file() {
    local file=$1
    [ -f "$file" ] || return
    case $file in
      *index.scss)
        $SED \
          -e '1s|^|---\n---\n\n|' \
          -e 's|@import url\(["'\'']?([^"'\'']+)\.css["'\'']?\);|@use "\1";|g' \
          "$file"
        ;;
      *index.html)
        $SED \
          -e '1s|^|---\n---\n{% include path.html -%}\n\n|' \
          -e '/<!-- <base href="\/"> -->/d' \
          -e 's|href="(styles/[^"]+)"|href="{{ path }}\1?v={{ site.v }}"|g' \
          -e 's|href="(assets/[^"]+)"|href="{{ path }}\1"|g' \
          -e 's|<meta property="og:image" content="([^"]*)"|<meta property="og:image" content="{{ path }}\1"|g' \
          -e 's|src="(scripts/)([^"]+)"|src="{{ path }}\1dist/\2?v={{ site.v }}"|g' \
          -e 's|src="([^"]+)"|src="{{ path }}\1"|g' \
          -e 's|src="\{\{ path \}\}\{\{ path \}\}([^"]*)"|src="{{ path }}\1"|g' \
          -e 's|<script([^>]*) defer([^>]*)>|<script\1\2 defer>|g' \
          -e 's|<script([^>]*) type="module"([^>]*)>|<script\1\2 defer>|g' \
          "$file"
        ;;
    esac
  }

  process_file "$styles_dir/index.scss"
  process_file "$tmp_dir/index.html"

  mkdir -p $starter_dir
  cp -r "$tmp_dir"/* "$starter_dir"/ || { echo "Failed to copy files to $starter_dir"; exit 1; }

  $SED "s/^enable_start=[0-1]/enable_start=0/" "$0"
  find "$tmp_dir" "$starter_dir" . -type f -name "*''" -delete
  echo "Project setup completed!"
}

main $@
