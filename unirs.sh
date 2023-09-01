#!/bin/sh
export TERM=ansi

error_exit() {
  printf "%s\n" "$1" >&2
  exit 1
}

get_username_and_password() {
  username=$(whiptail --inputbox "Enter a name for the user account:" 10 70 3>&1 1>&2 2>&3 3>&1) || exit 1;
  username_len=$(printf "%s" "$username" | wc -m)
  while ! printf "%s" "$username" | grep -q "^[a-z][a-z0-9_-]*$" || [ "$username_len" -gt 32 ]; do
    username=$(whiptail --inputbox "Username not valid. Please enter a username beginning with a letter, with all lowercase letters, numbers, -, or _, and under 32 characters long." 10 70 3>&1 1>&2 2>&3 3>&1) || exit 1;
    username_len=$(printf "%s" "$username" | wc -m)
  done
  password=$(whiptail --passwordbox "Enter a password for that user:" 8 70 3>&1 1>&2 2>&3 3>&1) || exit 1;
  password_2=$(whiptail --passwordbox "Retype password:" 8 70 3>&1 1>&2 2>&3 3>&1) || exit 1;
  while [ "$password" != "$password_2" ] ; do
    unset password password_2
    password=$(whiptail --passwordbox "Passwords do not match... Enter:" 8 70 3>&1 1>&2 2>&3 3>&1) || exit 1;
    password_2=$(whiptail --passwordbox "Retype password:" 8 70 3>&1 1>&2 2>&3 3>&1) || exit 1;
  done;
}

add_user_with_pass() {
  name="$1"
  pass="$2"
  [ -z "$3" ] && user_shell=/bin/bash || user_shell="$3"
  whiptail --infobox "Adding user, setting password..." 7 50
  useradd -m -g wheel -s "$user_shell" "$name" > /dev/null 2>&1 || usermod -a -G wheel "$name" && mkdir -p /home/"$name" && chown "$name":wheel /home/"$name"
  export source_dir="/home/${name}/.local/src"
  mkdir -p "$source_dir"
  chown -R "$name":wheel "$(dirname "$source_dir")"
  if [ -n "$pass" ]; then
    printf "%s" "$name:$pass" | chpasswd
  fi
  unset name pass
}

welcome_msg() {
  whiptail --title "Welcome!" --msgbox "Welcome to UNIRS, UserNyan's Incredible Ricing Script! This script will install my desktop environment under a new user on your arch linux system." 10 60
  whiptail --title "Info" --yes-button "Ok" --no-button "Exit" --yesno "Make sure you have the current pacman updates and refreshed Arch keyrings.\\n\\nIf not, some programs might fail to install." 8 70
}

install_msg() {
  whiptail --title "Info" --yes-button "Ready!" --no-button "Not Ready Yet..." --yesno "The rest of the installation is automated. Just press <Ready!> to start it." 10 60 ||
  {
    clear
    exit 1
  }
}

pacman_key_refresh() {
  whiptail --infobox "Refreshing Arch keyring..." 7 50
  pacman --noconfirm -S archlinux-keyring > /dev/null 2>&1;
}

install_aur_pkg_manually() {
  #TODO: edit config to compile with all cores or figure out some other way of using all cores
  pkg_name="$1"
  pkg_source="https://aur.archlinux.org/${pkg_name}.git"
  if [ "$#" -gt 1 ]; then
    pkg_source="$2"
  fi
  working_dir="${source_dir}/${pkg_name}"
  pacman -Qq "$pkg_name" > /dev/null 2>&1 && return 0
  whiptail --infobox "Installing \"$1\" manually." 7 50
  sudo -u "$username" mkdir -p "$working_dir"
  sudo -u "$username" git -C "$source_dir" clone "$pkg_source" "$working_dir" --depth 1 --single-branch --no-tags -q ||
    {
      [ -d "$working_dir" ] || return 1
      sudo -u "$username" git -C "$working_dir" pull --force origin master
    }
  [ -d "$working_dir" ] || return 1
  ( cd "$working_dir" && sudo -u "$username" makepkg --clean -si --noconfirm > /dev/null 2>&1) || return 1
}

install_pkg() {
  pacman --noconfirm --needed -S "$1" > /dev/null 2>&1
}

install_aur_pkg() {
  sudo -u "$username" $AUR_HELPER --noconfirm -S "$1" > /dev/null 2>&1
}

install_pkgbuild() {
  curl -L "$1" --output "$source_dir/makepkg_temp/PKGBUILD" > /dev/null 2>&1
  (cd "$source_dir" && sudo -u "$username" makepkg -si --clean --noconfirm > /dev/null 2>&1) || return 1
}

install_git_make() {
  # 1 : repo url
  # 2 : folder name
  output_dir="$source_dir"/"$2"
  sudo -u "$username" git -C "$source_dir" clone "$1" "$output_dir" --depth 1 --single-branch --no-tags -q || {
    [ -d "$output_dir" ] || return 1
    sudo -u "$username" git -C "$output_dir" pull
  }
  make --silent -C "$output_dir" clean > /dev/null 2>&1
  make -C "$output_dir" > /dev/null 2>&1
  make --silent -C "$output_dir" install > /dev/null 2>&1
  unset output_dir
}

install_program_list() {
  whiptail --infobox "Installing programs from program list..." 7 50
  #get the program list
  if [ -f "$PROGRAM_LIST_FILE" ]; then
    cp "$PROGRAM_LIST_FILE" /tmp/program_list.csv
  else
    curl -Ls "$PROGRAM_LIST_FILE_SOURCE" > /tmp/program_list.csv
  fi
  sed -i "/^#/d;/^$/d" /tmp/program_list.csv
  #append a newline to the last line in the file if one is missing
  if [ "$(cat -e /tmp/program_list.csv | tail -c 2)" = "%" ]; then
    sed -i "/$ s/$/\n/" /tmp/program_list.csv
  fi

  mkdir -p "$source_dir/makepkg_temp"
  trap 'rm -rf $source_dir/makepkg_temp' HUP INT QUIT TERM PWR EXIT
  while IFS=, read -r tag name source purpose; do
    [ -z "$name" ] && name="$source"
    #remove quotes from purpose
    printf "%s" "$purpose" | grep -q "^\".*\"$" &&
      purpose="$(printf "%s" "$purpose" | sed 's/^.//;s/.$//')"
    #
    whiptail --infobox "${name} ${purpose}" 10 50
    if   [ "$tag" = "" ]; then
      # A package in the main arch repos
      install_pkg "$source"
    elif [ "$tag" = "AUR" ]; then
      # A package in the AUR
      install_aur_pkg "$source"
    elif [ "$tag" = "PKGBUILD" ]; then
      # A link directly to a PKGBUILD file
      install_pkgbuild "$source"
    elif [ "$tag" = "GIT_MAKEINSTALL" ]; then
      # A link to a git repo installed with 'make install'
      install_git_make "$source" "$name"
    fi
    #-DEBUG-
    # sleep 1
    #printf "%s, %s, %s\n" "$tag" "$source" "$purpose"
  done < /tmp/program_list.csv;
}

#TODO: acknowledge the branch argument
drop_git_repo() {
  src="$1"
  dest="$2"
  branch="$3" #optional
  temp_dir="$(mktemp -d)"
  sudo chown "$username":wheel "$temp_dir"
  sudo -u "$username" chown "$username":wheel "$dest" "$temp_dir"
  [ ! -d "$dest" ] && mkdir -p "$2"
  whiptail --infobox "Installing config files" 7 50
  sudo -u "$username" git clone "$src" "$temp_dir" "${branch:+--branch="$branch"}"  --depth 1 --single-branch --no-tags -q --recursive --recurse-submodules
  sudo -u "$username" cp -rfT "$temp_dir" "$dest"
}
  
AUR_HELPER=yay
PROGRAM_LIST_FILE=programs_list.csv
#placeholder for later
PROGRAM_LIST_FILE_SOURCE=https://example.com/programs_list.csv
DOTFILE_REPO=/usr/src/unirs-dotfiles

main() {
  # install whiptail
  pacman --noconfirm -Sy --needed libnewt || error_exit "Are you sure you\'re running as root, are on an Arch system, and have an internet connection?"
  welcome_msg || error_exit "user exited"
  get_username_and_password || error_exit "User exited"

  install_msg || error_exit "User exited"

  pacman_key_refresh || error_exit "Error refreshing Arch keyring"

  whiptail --infobox "Installing script's dependencies..." 10 50
  for pkg in curl ca-certificates base-devel git ntp bash; do
    install_pkg "$pkg"
  done

  whiptail --infobox "Synchronizing system time." 10 50

  ntpd -q -g >/dev/null 2>&1

  add_user_with_pass "$username" "$password" || error_exit "Error creating new user"
  #forget the password, it's not needed anymore
  unset password password_2

  #give our user temporary permission to run sudo without a password
  #required for builds that use AUR packages, since they require a fakeroot environment
  trap 'rm -f /etc/sudoers.d/unirs-temp' HUP INT QUIT TERM PWR EXIT
  printf "%s" "$username ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/unirs-temp

  #make pacman colorful
  grep -q '^ILoveCandy' /etc/pacman.conf || sed -i "/#VerbosePkgLists/a ILoveCandy" /etc/pacman.conf
  sed -i "s/#Color$/Color/" /etc/pacman.conf
  sed -i "s/^#ParallelDownloads.*/ParallelDownloads = 5/;" /etc/pacman.conf

  install_aur_pkg_manually "$AUR_HELPER" || error_exit "Error installing AUR helper"

  install_program_list || error_exit "Error installing list of programs"

  #enable services
  services="bluetooth NetworkManager"
  for x in $services; do
    systemctl enable --now "$x"
  done

  cd /home/"$username"

  drop_git_repo "$DOTFILE_REPO" /home/"$username" master
  rm -rf README.md LICENSE.txt .git

  #NO BEEPING
  printf "%s" "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf
}

main "$@"
