#!/bin/bash
set -e

detect_os() {
  case "$(uname -s)" in
    Darwin) printf "macos" ;;
    Linux)  printf "linux" ;;
    *)      printf "unknown" ;;
  esac
}

get_startup_script() {
  case $SHELL in
    */sh)   printf "$HOME/.profile" ;;
    */bash) printf "$HOME/.bashrc" ;;
    */zsh)  printf "$HOME/.zshrc" ;;
    *)      printf "unsupported" ;;
  esac
}

generate_aliases() {
cat <<EOF
$ALIASES_FIRST_LINE
source $HOME/.local/bin/gpvm_ssh_wrapper.sh
$ALIASES_LAST_LINE
EOF
}

generate_config_file() {
  mkdir -pv $HOME/.local/etc
cat <<EOF > "$HOME/.local/etc/gpvm-scanner-config"
# GPVM Scanner Configuration File
# Each line represents a GPVM group to scan
# name|domain|user|index_min|index_max|except
dunegpvm|fnal.gov|wyjang|01|15|01-02,10
icarusgpvm|fnal.gov|wyjang|01|06|01
EOF
}

copy_files() {
  mkdir -pv "$HOME/.local/bin"
  mkdir -pv "$HOME/.local/etc"
  mkdir -pv "$HOME/.config/systemd/user"

  cp -v "gpvm-scanner.sh" "$HOME/.local/bin/gpvm-scanner.sh"
  cp -v "gpvm_ssh_wrapper.sh" "$HOME/.local/bin/gpvm_ssh_wrapper.sh"
  if [ "$OS_TYPE" = "macos" ]; then
    cp -v "com.user.gpvm-scanner.plist" "$HOME/Library/LaunchAgents/com.user.gpvm-scanner.plist"
  elif [ "$OS_TYPE" = "linux" ]; then
    cp -v "gpvm-scanner.service" "$HOME/.config/systemd/user/gpvm-scanner.service"
    cp -v "gpvm-scanner.timer" "$HOME/.config/systemd/user/gpvm-scanner.timer"
  fi
}

remove_files() {
  if [ "$OS_TYPE" = "macos" ]; then
    rm -v "$HOME/Library/LaunchAgents/com.user.gpvm-scanner.plist"
  elif [ "$OS_TYPE" = "linux" ]; then
    rm -v "$HOME/.config/systemd/user/gpvm-scanner.service"
    rm -v "$HOME/.config/systemd/user/gpvm-scanner.timer"
  fi
}

add_alias_to_startup() {
  if ! grep -Fxq "$ALIASES_FIRST_LINE" "$STARTUP_SCRIPT"; then
    {
      echo ""
      generate_aliases
    } >> "$STARTUP_SCRIPT"
    printf "Aliases added to %s\n" "$STARTUP_SCRIPT"
  else
    printf "Aliases already exist in %s\n" "$STARTUP_SCRIPT"
  fi
}

remove_alias_from_startup() {
  if grep -Fxq "$ALIASES_FIRST_LINE" "$STARTUP_SCRIPT"; then
    sed -i.bak "/$ALIASES_FIRST_LINE/,/$ALIASES_LAST_LINE/d" "$STARTUP_SCRIPT"
    rm -f "$STARTUP_SCRIPT.bak"
    printf "Aliases removed from %s\n" "$STARTUP_SCRIPT"
  else
    printf "No aliases found in %s\n" "$STARTUP_SCRIPT"
  fi
}

stop_gpvm_scanner_service() {
  if [ "$OS_TYPE" = "macos" ]; then
    launchctl unload "$HOME/Library/LaunchAgents/com.user.gpvm-scanner.plist" 2>/dev/null || true
  elif [ "$OS_TYPE" = "linux" ]; then
    systemctl --user stop gpvm-scanner.timer 2>/dev/null || true
    systemctl --user disable gpvm-scanner.timer 2>/dev/null || true
  fi
}

print_instruction() {
  if [ "$OS_TYPE" = "macos" ]; then
    printf "To start the gpvm-scanner agent, run:\nlaunchctl load %s/Library/LaunchAgents/com.user.gpvm-scanner.plist\n" "$HOME"
    printf "To stop the gpvm-scanner agent, run:\nlaunchctl stop %s/Library/LaunchAgents/com.user.gpvm-scanner.plist\n" "$HOME"
  elif [ "$OS_TYPE" = "linux" ]; then
    printf "To start the gpvm-scanner service, run:\nsystemctl --user enable --now gpvm-scanner.timer\nsystemctl --user enable --now gpvm-scanner.service &\n"
    printf "To stop the gpvm-scanner service, run:\nsystemctl --user disable --now gpvm-scanner.timer\nsystemctl --user stop gpvm-scanner.service &\n"
  fi
}

main() {
  OS_TYPE=$(detect_os)
  STARTUP_SCRIPT=$(get_startup_script)
  ALIASES_FIRST_LINE="# GPVM Scanner Aliases Start"
  ALIASES_LAST_LINE="# GPVM Scanner Aliases End"
  generate_config_file

  MODE="install"
  if [ -z "$1" ]; then
    :
  elif [ "$1" = "--install" ]; then
    MODE="install"
  elif [ "$1" = "--uninstall" ]; then
    MODE="uninstall"
  else
    printf "Error: Unknown argument: %s\n" "$1" >&2
    printf "Usage: $0 [--install|--uninstall]\n"
    exit 1
  fi

  case $MODE in
    install)
      copy_files
      add_alias_to_startup
      print_instruction
      ;;
    uninstall)
      stop_gpvm_scanner_service
      remove_files
      remove_alias_from_startup
      ;;
    *)
      printf "Error: Unknown mode: %s\n" "$MODE" >&2
      exit 1
      ;;
  esac
  return 0
}

main "$@"
