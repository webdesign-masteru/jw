#!/bin/bash

# Set error handling
set -e  # Exit on error

# Configuration variables
output_dir="dist/"
deploy_server="user@server.com:path/to/public_html/"
rsync_options="-avz --delete --delete-excluded --include=*.htaccess"
jekyll_config="_config.yml,_config_dev.yml"
js_source_dir="src/scripts/*.js"
js_output_dir="src/scripts/dist/"
preview_host="192.168.1.126"
preview_port="3000"
backup_compression_options="-t7z -mx=9 -m0=LZMA2 -mmt=on"
backup_date_format="+%d-%m-%Y"
enable_start=0

# Function to get directory name
get_dir_name() {
  basename "$(pwd)"
}

# Function to get current date (cross-platform)
get_current_date() {
  date $backup_date_format
}

# Function to check dependencies
check_deps() {
  local deps=($@)
  local missing=()

  for dep in "${deps[@]}"; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
  done

  if [ ${#missing[@]} -ne 0 ]; then
    echo "${missing[*]} is not installed"
    exit 1
  fi
}

# Docker functions
up() {
  check_deps "docker-compose"
  sudo chmod -R 777 .
  docker-compose up -d
}
down() {
  check_deps "docker-compose"
  docker-compose down
}
bash() {
  check_deps "docker-compose"
  docker-compose exec jekyll bash
}
prune() {
  check_deps "docker"
  docker system prune -af --volumes
}

# Build-related functions
build_js() {
  esbuild $js_source_dir --bundle --outdir=$js_output_dir --minify
}

build_jekyll() {
  jekyll build
}

# Main commands
dev() {
  check_deps "jekyll" "esbuild"
  trap clean INT
  jekyll serve --host 0.0.0.0 --watch --force_polling --livereload --incremental --config $jekyll_config &
  esbuild $js_source_dir --bundle --outdir=$js_output_dir --minify --watch
  wait
}

build() {
  check_deps "jekyll" "esbuild"
  build_js
  build_jekyll
}

deploy() {
  check_deps "jekyll" "esbuild" "rsync"
  trap clean INT
  jekyll clean
  build_js
  build_jekyll
  rsync $rsync_options $output_dir $deploy_server || { echo "Deploy failed: rsync error"; exit 1; }
  jekyll clean
}

backup() {
  check_deps "7z"
  jekyll clean
  local dir_name=$(get_dir_name)
  local current_date=$(get_current_date)
  7z a $backup_compression_options -x!$dir_name/dist -x!$dir_name/node_modules ./$dir_name-$current_date.7z $(pwd)
}

preview() {
  check_deps "jekyll"
  trap clean INT
  jekyll serve --watch --host $preview_host --port $preview_port
}

watch() {
  check_deps "esbuild" "jekyll"
  trap clean INT
  jekyll build --watch --force_polling &
  esbuild $js_source_dir --bundle --outdir=$js_output_dir --minify --watch
  wait
}

clean() {
  check_deps "jekyll"
  jekyll clean
}

# Handle arguments
main() {
  case $1 in
    "dev")     dev     ;;
    "build")   build   ;;
    "deploy")  deploy  ;;
    "backup")  backup  ;;
    "preview") preview ;;
    "watch")   watch   ;;
    "clean")   clean   ;;
    "up")      up      ;;
    "down")    down    ;;
    "bash")    bash    ;;
    "prune")   prune   ;;
    "start")   start   ;;
    *)
      echo "Usage: $0 { dev | build | deploy | backup | preview | watch | clean | up | down | bash | prune }"
      exit 1
      ;;
  esac
}

# Function to start new project with Starter
starter_repo="https://github.com/agragregra/starter"
starter_dir="src"
start() {
  check_deps "git"

  if [ $enable_start -eq 0 ]; then
    echo "Command 'start' is disabled."
    exit 1
  fi

  echo "Are you sure you want to run 'start'? yes/no"
  read -r response
  [[ "$response" != "yes" ]] && { echo "Operation canceled."; exit 0; }

  echo "Cloning starter project to temporary directory..."
  tmp_dir="/tmp/starter_tmp_$$"
  rm -rf "$tmp_dir"
  git clone "$starter_repo" "$tmp_dir" || { echo "Failed to clone repository"; exit 1; }
  echo "Cleaning tmp files..."
  rm -rf "$tmp_dir/trunk" "$tmp_dir/.gitignore" "$tmp_dir/.git" "$tmp_dir/readme.md" "$starter_dir/assets/images/favicon.ico"

  echo "Renaming style files..."
  styles_dir="$tmp_dir/styles"
  if [[ -d "$styles_dir" ]]; then
    for file in "$styles_dir"/*.css; do
      [[ -f "$file" ]] || continue
      filename=$(basename "$file" .css)
      if [[ "$filename" == "index" ]]; then
        mv "$file" "$styles_dir/index.scss"
      else
        mv "$file" "$styles_dir/_$filename.css"
      fi
    done
  fi

  echo "Updating index.scss..."
  index_scss="$styles_dir/index.scss"
  if [[ -f "$index_scss" ]]; then
    sed -E -i \
      -e 's|@import url\(["'\'']?([^"'\'']+)\.css["'\'']?\);|@use "\1";|g' \
      -e '1s|^|---\n---\n\n|' "$index_scss" || echo "Warning: Failed to update index.scss"
  fi

  echo "Updating index.html..."
  index_html="$tmp_dir/index.html"
  if [[ -f "$index_html" ]]; then
    sed -E -i \
      -e '1s|^|---\n---\n{% include path.html -%}\n\n|' \
      -e '/<!-- <base href="\/"> -->/d' \
      -e 's|href="(styles/[^"]+)"|href="{{ path }}\1"|g' \
      -e 's|href="(assets/[^"]+)"|href="{{ path }}\1"|g' \
      -e 's|<meta property="og:image" content="([^"]*)"|<meta property="og:image" content="{{ path }}\1"|g' \
      "$index_html" || echo "Warning: Failed to update index.html (step 1)"
    sed -E -i \
      -e 's|src="(scripts/)([^"]+)"|src="{{ path }}\1dist/\2"|g' \
      -e 's|src="([^"]+)"|src="{{ path }}\1"|g' \
      -e 's|src="\{\{ path \}\}\{\{ path \}\}([^"]*)"|src="{{ path }}\1"|g' \
      "$index_html" || echo "Warning: Failed to update src attributes"
    sed -E -i 's|<script([^>]*) defer([^>]*)>|<script\1\2 defer>|g' "$index_html" || echo "Warning: Failed to move defer"
    sed -E -i 's|<script([^>]*) type="module"([^>]*)>|<script\1\2 defer>|g' "$index_html" || echo "Warning: Failed to replace type=module"
  fi

  echo "Merging into target directory..."
  mkdir -p "$starter_dir"
  cp -r "$tmp_dir/." "$starter_dir/" || { echo "Failed to copy files to $starter_dir"; exit 1; }
  rm -rf "$tmp_dir"

  echo "Project setup completed!"
}

main $@
