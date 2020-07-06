#!/bin/bash
# ffmpeg windows cross compile helper/download script, see github repo README
# Copyright (C) 2012 Roger Pack, the script is under the GPLv3, but output FFmpeg's executables aren't
# set -x

yes_no_sel () {
  unset user_input
  local question="$1"
  shift
  local default_answer="$1"
  while [[ "$user_input" != [YyNn] ]]; do
    echo -n "$question"
    read user_input
    if [[ -z "$user_input" ]]; then
      echo "using default $default_answer"
      user_input=$default_answer
    fi
    if [[ "$user_input" != [YyNn] ]]; then
      clear; echo 'Your selection was not vaild, please try again.'; echo
    fi
  done
  # downcase it
  user_input=$(echo $user_input | tr '[A-Z]' '[a-z]')
}

set_box_memory_size_bytes() {
  if [[ $OSTYPE == darwin* ]]; then
    box_memory_size_bytes=20000000000 # 20G fake it out for now :|
  else
    local ram_kilobytes=`grep MemTotal /proc/meminfo | awk '{print $2}'`
    local swap_kilobytes=`grep SwapTotal /proc/meminfo | awk '{print $2}'`
    box_memory_size_bytes=$[ram_kilobytes * 1024 + swap_kilobytes * 1024]
  fi
}

sortable_version() {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }';
}

at_least_required_version() { # params: required actual
  local sortable_required=$(sortable_version $1)
  sortable_required=$(echo $sortable_required | sed 's/^0*//') # remove preceding zeroes, which bash later interprets as octal or screwy
  local sortable_actual=$(sortable_version $2)
  sortable_actual=$(echo $sortable_actual | sed 's/^0*//')
  [[ "$sortable_actual" -ge "$sortable_required" ]]
}

check_missing_packages () {
  # We will need this later if we don't want to just constantly be grepping the /etc/os-release file
  if [ -z "${VENDOR}" ] && grep -E '(centos|rhel)' /etc/os-release &> /dev/null; then
    # In RHEL this should always be set anyway. But not so sure about CentOS
    VENDOR="redhat"
  fi
  # zeranoe's build scripts use wget, though we don't here...
  local check_packages=('ragel' 'curl' 'pkg-config' 'make' 'git' 'svn' 'gcc' 'autoconf' 'automake' 'yasm' 'cvs' 'flex' 'bison' 'makeinfo' 'g++' 'ed' 'hg' 'pax' 'unzip' 'patch' 'wget' 'xz' 'nasm' 'gperf' 'autogen' 'bzip2' 'realpath' 'meson' 'clang' 'python')
  # autoconf-archive is just for leptonica FWIW
  # I'm not actually sure if VENDOR being set to centos is a thing or not. On all the centos boxes I can test on it's not been set at all.
  # that being said, if it where set I would imagine it would be set to centos... And this contition will satisfy the "Is not initially set"
  # case because the above code will assign "redhat" all the time.
  if [ -z "${VENDOR}" ] || [ "${VENDOR}" != "redhat" ] && [ "${VENDOR}" != "centos" ]; then
    check_packages+=('cmake')
  fi
  # libtool check is wonky...
  if [[ $OSTYPE == darwin* ]]; then
    check_packages+=('glibtoolize') # homebrew special :|
  else
    check_packages+=('libtoolize') # the rest of the world
  fi
  # Use hash to check if the packages exist or not. Type is a bash builtin which I'm told behaves differently between different versions of bash.
  for package in "${check_packages[@]}"; do
    hash "$package" &> /dev/null || missing_packages=("$package" "${missing_packages[@]}")
  done
  if [ "${VENDOR}" = "redhat" ] || [ "${VENDOR}" = "centos" ]; then
    if [ -n "$(hash cmake 2>&1)" ] && [ -n "$(hash cmake3 2>&1)" ]; then missing_packages=('cmake' "${missing_packages[@]}"); fi
  fi
  if [[ -n "${missing_packages[@]}" ]]; then
    clear
    echo "Could not find the following execs (svn is actually package subversion, makeinfo is actually package texinfo, hg is actually package mercurial if you're missing them): ${missing_packages[*]}"
    echo 'Install the missing packages before running this script.'
    determine_distro
    if [[ $DISTRO == "Ubuntu" ]]; then
      echo "for ubuntu:"
      echo "$ sudo apt-get update"
      echo -n " $ sudo apt-get install subversion ragel curl texinfo g++ bison flex cvs yasm automake libtool autoconf gcc cmake git make pkg-config zlib1g-dev mercurial unzip pax nasm gperf autogen bzip2 autoconf-archive p7zip-full meson clang"
      if at_least_required_version "18.04" "$(lsb_release -rs)"; then
        echo -n " python3-distutils" # guess it's no longer built-in, lensfun requires it...
      fi
      if at_least_required_version "20.04" "$(lsb_release -rs)"; then
        echo -n " python-is-python3"  # needed
      fi
      echo " -y"
    else
      echo "for OS X (homebrew): brew install ragel wget cvs hg yasm autogen automake autoconf cmake libtool xz pkg-config nasm bzip2 autoconf-archive p7zip coreutils meson llvm" # if edit this edit docker/Dockerfile also :|
      echo "   and set llvm to your PATH if on catalina"
      echo "for debian: same as ubuntu, but also add libtool-bin, ed"
      echo "for RHEL/CentOS: First ensure you have epel repo available, then run $ sudo yum install ragel subversion texinfo mercurial libtool autogen gperf nasm patch unzip pax ed gcc-c++ bison flex yasm automake autoconf gcc zlib-devel cvs bzip2 cmake3 -y"
      echo "for fedora: if your distribution comes with a modern version of cmake then use the same as RHEL/CentOS but replace cmake3 with cmake."
      echo "for linux native compiler option: same as <your OS> above, also add libva-dev"
    fi
    exit 1
  fi

  export REQUIRED_CMAKE_VERSION="3.0.0"
  for cmake_binary in 'cmake' 'cmake3'; do
    # We need to check both binaries the same way because the check for installed packages will work if *only* cmake3 is installed or
    # if *only* cmake is installed.
    # On top of that we ideally would handle the case where someone may have patched their version of cmake themselves, locally, but if
    # the version of cmake required move up to, say, 3.1.0 and the cmake3 package still only pulls in 3.0.0 flat, then the user having manually
    # installed cmake at a higher version wouldn't be detected.
    if hash "${cmake_binary}"  &> /dev/null; then
      cmake_version="$( "${cmake_binary}" --version | sed -e "s#${cmake_binary}##g" | head -n 1 | tr -cd '[0-9.\n]' )"
      if at_least_required_version "${REQUIRED_CMAKE_VERSION}" "${cmake_version}"; then
        export cmake_command="${cmake_binary}"
        break
      else
        echo "your ${cmake_binary} version is too old ${cmake_version} wanted ${REQUIRED_CMAKE_VERSION}"
      fi 
    fi
  done

  # If cmake_command never got assigned then there where no versions found which where sufficient.
  if [ -z "${cmake_command}" ]; then
    echo "there where no appropriate versions of cmake found on your machine."
    exit 1
  else
    # If cmake_command is set then either one of the cmake's is adequate.
    if [[ $cmake_command != "cmake" ]]; then # don't echo if it's the normal default
      echo "cmake binary for this build will be ${cmake_command}"
    fi
  fi

  if [[ ! -f /usr/include/zlib.h ]]; then
    echo "warning: you may need to install zlib development headers first if you want to build mp4-box [on ubuntu: $ apt-get install zlib1g-dev] [on redhat/fedora distros: $ yum install zlib-devel]" # XXX do like configure does and attempt to compile and include zlib.h instead?
    sleep 1
  fi

  # TODO nasm version :|

  # doing the cut thing with an assigned variable dies on the version of yasm I have installed (which I'm pretty sure is the RHEL default)
  # because of all the trailing lines of stuff
  export REQUIRED_YASM_VERSION="1.2.0" # export ???
  local yasm_binary=yasm
  local yasm_version="$( "${yasm_binary}" --version |sed -e "s#${yasm_binary}##g" | head -n 1 | tr -dc '[0-9.\n]' )"
  if ! at_least_required_version "${REQUIRED_YASM_VERSION}" "${yasm_version}"; then
    echo "your yasm version is too old $yasm_version wanted ${REQUIRED_YASM_VERSION}"
    exit 1
  fi
  local meson_version=`meson --version`
  if ! at_least_required_version "0.47" "${meson_version}"; then
    echo "your meson version is too old $meson_version wanted 0.47"
    exit 1
  fi
  # also check missing "setup" so it's early LOL
  if uname -a | grep  -q -- "-Microsoft " ; then
    if cat /proc/sys/fs/binfmt_misc/WSLInterop | grep -q enabled ; then
      echo "windows WSL detected: you must first disable 'binfmt' by running this 
      sudo bash -c 'echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop'
      then try again"
      exit 1
    fi
  fi

}

determine_distro() { 

# Determine OS platform from https://askubuntu.com/a/459425/20972
UNAME=$(uname | tr "[:upper:]" "[:lower:]")
# If Linux, try to determine specific distribution
if [ "$UNAME" == "linux" ]; then
    # If available, use LSB to identify distribution
    if [ -f /etc/lsb-release -o -d /etc/lsb-release.d ]; then
        export DISTRO=$(lsb_release -i | cut -d: -f2 | sed s/'^\t'//)
    # Otherwise, use release info file
    else
        export DISTRO=$(ls -d /etc/[A-Za-z]*[_-][rv]e[lr]* | grep -v "lsb" | cut -d'/' -f3 | cut -d'-' -f1 | cut -d'_' -f1)
    fi
fi
# For everything else (or if above failed), just use generic identifier
[ "$DISTRO" == "" ] && export DISTRO=$UNAME
unset UNAME
}


intro() {
  cat <<EOL
     ##################### Welcome ######################
  Welcome to the ffmpeg cross-compile builder-helper script.
  Downloads and builds will be installed to directories within $cur_dir
  If this is not ok, then exit now, and cd to the directory where you'd
  like them installed, then run this script again from there.
  NB that once you build your compilers, you can no longer rename/move
  the sandbox directory, since it will have some hard coded paths in there.
  You can, of course, rebuild ffmpeg from within it, etc.
EOL
  echo `date` # for timestamping super long builds LOL
  if [[ $sandbox_ok != 'y' && ! -d sandbox ]]; then
    echo
    echo "Building in $PWD/sandbox, will use ~ 4GB space!"
    echo
  fi
  mkdir -p "$cur_dir"
  cd "$cur_dir"
  if [[ $disable_nonfree = "y" ]]; then
    non_free="n"
  else
    if  [[ $disable_nonfree = "n" ]]; then
      non_free="y"
    else
      yes_no_sel "Would you like to include non-free (non GPL compatible) libraries, like [libfdk_aac,decklink -- note that the internal AAC encoder is ruled almost as high a quality as fdk-aac these days]
The resultant binary may not be distributable, but can be useful for in-house use. Include these non-free license libraries [y/N]?" "n"
      non_free="$user_input" # save it away
    fi
  fi
  echo "sit back, this may take awhile..."
}

pick_compiler_flavors() {
  while [[ "$compiler_flavors" != [1-5] ]]; do
    if [[ -n "${unknown_opts[@]}" ]]; then
      echo -n 'Unknown option(s)'
      for unknown_opt in "${unknown_opts[@]}"; do
        echo -n " '$unknown_opt'"
      done
      echo ', ignored.'; echo
    fi
    cat <<'EOF'
What version of MinGW-w64 would you like to build or update?
  1. Both Win32 and Win64
  2. Win32 (32-bit only)
  3. Win64 (64-bit only)
  4. Local native
  5. Exit
EOF
    echo -n 'Input your choice [1-5]: '
    read compiler_flavors
  done
  case "$compiler_flavors" in
  1 ) compiler_flavors=multi ;;
  2 ) compiler_flavors=win32 ;;
  3 ) compiler_flavors=win64 ;;
  4 ) compiler_flavors=native ;;
  5 ) echo "exiting"; exit 0 ;;
  * ) clear;  echo 'Your choice was not valid, please try again.'; echo ;;
  esac
}

# made into a method so I don't/don't have to download this script every time if only doing just 32 or just6 64 bit builds...
download_gcc_build_script() {
    local zeranoe_script_name=$1
    rm -f $zeranoe_script_name || exit 1
    curl -4 file://$patch_dir/$zeranoe_script_name -O --fail || exit 1
    chmod u+x $zeranoe_script_name
}

install_cross_compiler() {
  local win32_gcc="cross_compilers/mingw-w64-i686/bin/i686-w64-mingw32-gcc"
  local win64_gcc="cross_compilers/mingw-w64-x86_64/bin/x86_64-w64-mingw32-gcc"
  if [[ -f $win32_gcc && -f $win64_gcc ]]; then
   echo "MinGW-w64 compilers both already installed, not re-installing..."
   if [[ -z $compiler_flavors ]]; then
     echo "selecting multi build (both win32 and win64)...since both cross compilers are present assuming you want both..."
     compiler_flavors=multi
   fi
   return # early exit they've selected at least some kind by this point...
  fi

  if [[ -z $compiler_flavors ]]; then
    pick_compiler_flavors
  fi
  if [[ $compiler_flavors == "native" ]]; then
    echo "native build, not building any cross compilers..."
    return
  fi

  mkdir -p cross_compilers
  cd cross_compilers

    unset CFLAGS # don't want these "windows target" settings used the compiler itself since it creates executables to run on the local box (we have a parameter allowing them to set them for the script "all builds" basically)
    # pthreads version to avoid having to use cvs for it
    echo "Starting to download and build cross compile version of gcc [requires working internet access] with thread count $gcc_cpu_count..."
    echo ""

    # --disable-shared allows c++ to be distributed at all...which seemed necessary for some random dependency which happens to use/require c++...
    local zeranoe_script_name=mingw-w64-build-r22.local
    local zeranoe_script_options="--gcc-ver=10.1.0 --mingw-w64-ver=7.0.0 --default-configure --cpu-count=$gcc_cpu_count --disable-shared --clean-build --verbose --allow-overwrite --threads=winpthreads" # allow-overwrite to avoid some crufty prompts if I do rebuilds [or maybe should just nuke everything...]
    if [[ ($compiler_flavors == "win32" || $compiler_flavors == "multi") && ! -f ../$win32_gcc ]]; then
      echo "Building win32 cross compiler..."
      download_gcc_build_script $zeranoe_script_name
      if [[ `uname` =~ "5.1" ]]; then # Avoid using secure API functions for compatibility with msvcrt.dll on Windows XP.
        sed -i "s/ --enable-secure-api//" $zeranoe_script_name
      fi
      nice ./$zeranoe_script_name $zeranoe_script_options --build-type=win32 || exit 1
      if [[ ! -f ../$win32_gcc ]]; then
        echo "Failure building 32 bit gcc? Recommend nuke sandbox (rm -rf sandbox) and start over..."
        exit 1
      fi
      if [[ ! -f  ../cross_compilers/mingw-w64-i686/i686-w64-mingw32/lib/libmingwex.a ]]; then
	      echo "failure building mingwex? 32 bit"
	      exit 1
      fi
    fi
    if [[ ($compiler_flavors == "win64" || $compiler_flavors == "multi") && ! -f ../$win64_gcc ]]; then
      echo "Building win64 x86_64 cross compiler..."
      download_gcc_build_script $zeranoe_script_name
      nice ./$zeranoe_script_name $zeranoe_script_options --build-type=win64 || exit 1
      if [[ ! -f ../$win64_gcc ]]; then
        echo "Failure building 64 bit gcc? Recommend nuke sandbox (rm -rf sandbox) and start over..."
        exit 1
      fi
      if [[ ! -f  ../cross_compilers/mingw-w64-x86_64/x86_64-w64-mingw32/lib/libmingwex.a ]]; then
	      echo "failure building mingwex? 64 bit"
	      exit 1
      fi
    fi

    # rm -f build.log # leave resultant build log...sometimes useful...
    reset_cflags
  cd ..
  echo "Done building (or already built) MinGW-w64 cross-compiler(s) successfully..."
  echo `date` # so they can see how long it took :)
}

# helper methods for downloading and building projects that can take generic input

do_svn_checkout() {
  repo_url="$1"
  to_dir="$2"
  desired_revision="$3"
  if [ ! -d $to_dir ]; then
    echo "svn checking out to $to_dir"
    if [[ -z "$desired_revision" ]]; then
      svn checkout $repo_url $to_dir.tmp  --non-interactive --trust-server-cert || exit 1
    else
      svn checkout -r $desired_revision $repo_url $to_dir.tmp || exit 1
    fi
    mv $to_dir.tmp $to_dir
  else
    cd $to_dir
    echo "not svn Updating $to_dir since usually svn repo's aren't updated frequently enough..."
    # XXX accomodate for desired revision here if I ever uncomment the next line...
    # svn up
    cd ..
  fi
}

do_git_checkout() {
  local repo_url="$1"
  local to_dir="$2"
  if [[ -z $to_dir ]]; then
    to_dir=$(basename $repo_url | sed s/\.git/_git/) # http://y/abc.git -> abc_git
  fi
  local desired_branch="$3"
  if [ ! -d $to_dir ]; then
    echo "Downloading (via git clone) $to_dir from $repo_url"
    rm -rf $to_dir.tmp # just in case it was interrupted previously...
    git clone $repo_url $to_dir.tmp || exit 1
    # prevent partial checkouts by renaming it only after success
    mv $to_dir.tmp $to_dir
    echo "done git cloning to $to_dir"
    cd $to_dir
  else
    cd $to_dir
    if [[ $git_get_latest = "y" ]]; then
      git fetch # want this for later...
    else
      echo "not doing git get latest pull for latest code $to_dir" # too slow'ish...
    fi
  fi

  # reset will be useless if they didn't git_get_latest but pretty fast so who cares...plus what if they changed branches? :)
  old_git_version=`git rev-parse HEAD`
  if [[ -z $desired_branch ]]; then
    desired_branch="origin/master"
  fi
  echo "doing git checkout $desired_branch" 
  git checkout "$desired_branch" || (git_hard_reset && git checkout "$desired_branch") || (git reset --hard "$desired_branch") || exit 1 # can't just use merge -f because might "think" patch files already applied when their changes have been lost, etc...
  # vmaf on 16.04 needed that weird reset --hard? huh?
  if git show-ref --verify --quiet "refs/remotes/origin/$desired_branch"; then # $desired_branch is actually a branch, not a tag or commit
    git merge "origin/$desired_branch" || exit 1 # get incoming changes to a branch
  fi
  new_git_version=`git rev-parse HEAD`
  if [[ "$old_git_version" != "$new_git_version" ]]; then
    echo "got upstream changes, forcing re-configure. Doing git clean -f"
    git_hard_reset
  else
    echo "fetched no code changes, not forcing reconfigure for that..."
  fi
  cd ..
}

git_hard_reset() {
  git reset --hard # throw away results of patch files
  git clean -f # throw away local changes; 'already_*' and bak-files for instance.
}

get_small_touchfile_name() { # have to call with assignment like a=$(get_small...)
  local beginning="$1"
  local extra_stuff="$2"
  local touch_name="${beginning}_$(echo -- $extra_stuff $CFLAGS $LDFLAGS | /usr/bin/env md5sum)" # md5sum to make it smaller, cflags to force rebuild if changes
  touch_name=$(echo "$touch_name" | sed "s/ //g") # md5sum introduces spaces, remove them
  echo "$touch_name" # bash cruddy return system LOL
}

do_configure() {
  local configure_options="$1"
  local configure_name="$2"
  if [[ "$configure_name" = "" ]]; then
    configure_name="./configure"
  fi
  local cur_dir2=$(pwd)
  local english_name=$(basename $cur_dir2)
  local touch_name=$(get_small_touchfile_name already_configured "$configure_options $configure_name")
  if [ ! -f "$touch_name" ]; then
    # make uninstall # does weird things when run under ffmpeg src so disabled for now...

    echo "configuring $english_name ($PWD) as $ PKG_CONFIG_PATH=$PKG_CONFIG_PATH PATH=$mingw_bin_path:\$PATH $configure_name $configure_options" # say it now in case bootstrap fails etc.
    echo "all touch files" already_configured* touchname= "$touch_name" 
    echo "config options "$configure_options $configure_name""
    if [ -f bootstrap ]; then
      ./bootstrap # some need this to create ./configure :|
    fi
    if [[ ! -f $configure_name && -f bootstrap.sh ]]; then # fftw wants to only run this if no configure :|
      ./bootstrap.sh
    fi
    if [[ ! -f $configure_name ]]; then
      autoreconf -fiv # a handful of them require this to create ./configure :|
    fi
    rm -f already_* # reset
    nice -n 5 "$configure_name" $configure_options || exit 1 # less nice (since single thread, and what if you're running another ffmpeg nice build elsewhere?)
    touch -- "$touch_name"
    echo "doing preventative make clean"
    nice make clean -j $cpu_count # sometimes useful when files change, etc.
  #else
  #  echo "already configured $(basename $cur_dir2)"
  fi
}

do_make() {
  local extra_make_options="$1 -j $cpu_count"
  local cur_dir2=$(pwd)
  local touch_name=$(get_small_touchfile_name already_ran_make "$extra_make_options" )

  if [ ! -f $touch_name ]; then
    echo
    echo "Making $cur_dir2 as $ PATH=$mingw_bin_path:\$PATH make $extra_make_options"
    echo
    if [ ! -f configure ]; then
      nice make clean -j $cpu_count # just in case helpful if old junk left around and this is a 're make' and wasn't cleaned at reconfigure time
    fi
    nice make $extra_make_options || exit 1
    touch $touch_name || exit 1 # only touch if the build was OK
  else
    echo "Already made $(basename "$cur_dir2") ..."
  fi
}

do_make_and_make_install() {
  local extra_make_options="$1"
  do_make "$extra_make_options"
  do_make_install "$extra_make_options"
}

do_make_install() {
  local extra_make_install_options="$1"
  local override_make_install_options="$2" # startingly, some need/use something different than just 'make install'
  if [[ -z $override_make_install_options ]]; then
    local make_install_options="install $extra_make_install_options"
  else
    local make_install_options="$override_make_install_options $extra_make_install_options"
  fi
  local touch_name=$(get_small_touchfile_name already_ran_make_install "$make_install_options")
  if [ ! -f $touch_name ]; then
    echo "make installing $(pwd) as $ PATH=$mingw_bin_path:\$PATH make $make_install_options"
    nice make $make_install_options || exit 1
    touch $touch_name || exit 1
  fi
}

do_cmake() {
  extra_args="$1"
  local build_from_dir="$2"
  if [[ -z $build_from_dir ]]; then
    build_from_dir="."
  fi
  local touch_name=$(get_small_touchfile_name already_ran_cmake "$extra_args")

  if [ ! -f $touch_name ]; then
    rm -f already_* # reset so that make will run again if option just changed
    local cur_dir2=$(pwd)
    echo doing cmake in $cur_dir2 with PATH=$mingw_bin_path:\$PATH with extra_args=$extra_args like this:
    if [[ $compiler_flavors != "native" ]]; then
      local command="${build_from_dir} -DENABLE_STATIC_RUNTIME=1 -DBUILD_SHARED_LIBS=0 -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_FIND_ROOT_PATH=$mingw_w64_x86_64_prefix -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_RANLIB=${cross_prefix}ranlib -DCMAKE_C_COMPILER=${cross_prefix}gcc -DCMAKE_CXX_COMPILER=${cross_prefix}g++ -DCMAKE_RC_COMPILER=${cross_prefix}windres -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix $extra_args"
    else
      local command="${build_from_dir} -DENABLE_STATIC_RUNTIME=1 -DBUILD_SHARED_LIBS=0 -DCMAKE_INSTALL_PREFIX=$mingw_w64_x86_64_prefix $extra_args"
    fi
    echo "doing ${cmake_command}  -G\"Unix Makefiles\" $command"
    nice -n 5  ${cmake_command} -G"Unix Makefiles" $command || exit 1
    touch $touch_name || exit 1
  fi
}

do_cmake_from_build_dir() { # some sources don't allow it, weird XXX combine with the above :)
  source_dir="$1"
  extra_args="$2"
  do_cmake "$extra_args" "$source_dir"
}

do_cmake_and_install() {
  do_cmake "$1"
  do_make_and_make_install
}

do_meson() {
    local configure_options="$1 --unity=off"
    local configure_name="$2"
    local configure_env="$3"
    local configure_noclean=""
    if [[ "$configure_name" = "" ]]; then
        configure_name="meson"
    fi
    local cur_dir2=$(pwd)
    local english_name=$(basename $cur_dir2)
    local touch_name=$(get_small_touchfile_name already_built "$configure_options $configure_name $LDFLAGS $CFLAGS")
    if [ ! -f "$touch_name" ]; then
        if [ "$configure_noclean" != "noclean" ]; then
            make clean # just in case
        fi
        rm -f already_* # reset
        echo "Using meson: $english_name ($PWD) as $ PATH=$PATH ${configure_env} $configure_name $configure_options"
        #env
        "$configure_name" $configure_options || exit 1
        touch -- "$touch_name"
        make clean # just in case
    else
        echo "Already used meson $(basename $cur_dir2)"
    fi
}

generic_meson() {
    local extra_configure_options="$1"
    mkdir -pv build
    do_meson "--prefix=${mingw_w64_x86_64_prefix} --libdir=${mingw_w64_x86_64_prefix}/lib --buildtype=release --strip --default-library=static --cross-file=${top_dir}/meson-cross.mingw.txt $extra_configure_options . build"
}

generic_meson_ninja_install() {
    generic_meson "$1"
    do_ninja_and_ninja_install
}

do_ninja_and_ninja_install() {
    local extra_ninja_options="$1"
    do_ninja "$extra_ninja_options"
    local touch_name=$(get_small_touchfile_name already_ran_make_install "$extra_ninja_options")
    if [ ! -f $touch_name ]; then
        echo "ninja installing $(pwd) as $PATH=$PATH ninja -C build install $extra_make_options"
        ninja -C build install || exit 1
        touch $touch_name || exit 1
    fi
}

do_ninja() {
  local extra_make_options=" -j $cpu_count"
  local cur_dir2=$(pwd)
  local touch_name=$(get_small_touchfile_name already_ran_make "${extra_make_options}")

  if [ ! -f $touch_name ]; then
    echo
    echo "ninja-ing $cur_dir2 as $ PATH=$PATH ninja -C build "${extra_make_options}"
    echo
    ninja -C build "${extra_make_options} || exit 1
    touch $touch_name || exit 1 # only touch if the build was OK
  else
    echo "already did ninja $(basename "$cur_dir2")"
  fi
}

apply_patch() {
  local url=$1 # if you want it to use a local file instead of a url one [i.e. local file with local modifications] specify it like file://localhost/full/path/to/filename.patch
  local patch_type=$2
  if [[ -z $patch_type ]]; then
    patch_type="-p0" # some are -p1 unfortunately, git's default
  fi
  local patch_name=$(basename $url)
  local patch_done_name="$patch_name.done"
  if [[ ! -e $patch_done_name ]]; then
    if [[ -f $patch_name ]]; then
      rm $patch_name || exit 1 # remove old version in case it has been since updated on the server...
    fi
    curl -4 --retry 5 $url -O --fail || echo_and_exit "unable to download patch file $url"
    echo "applying patch $patch_name"
    patch $patch_type < "$patch_name" || exit 1
    touch $patch_done_name || exit 1
    # too crazy, you can't do do_configure then apply a patch?
    # rm -f already_ran* # if it's a new patch, reset everything too, in case it's really really really new
  #else
  #  echo "patch $patch_name already applied" # too chatty
  fi
}

echo_and_exit() {
  echo "failure, exiting: $1"
  exit 1
}

# takes a url, output_dir as params, output_dir optional
download_and_unpack_file() {
  url="$1"
  output_name=$(basename $url)
  output_dir="$2"
  if [[ -z $output_dir ]]; then
    output_dir=$(basename $url | sed s/\.tar\.*//) # remove .tar.xx
  fi
  if [ ! -f "$output_dir/unpacked.successfully" ]; then
    echo "downloading $url" # redownload in case failed...
    if [[ -f $output_name ]]; then
      rm $output_name || exit 1
    fi

    #  From man curl
    #  -4, --ipv4
    #  If curl is capable of resolving an address to multiple IP versions (which it is if it is  IPv6-capable),
    #  this option tells curl to resolve names to IPv4 addresses only.
    #  avoid a "network unreachable" error in certain [broken Ubuntu] configurations a user ran into once
    #  -L means "allow redirection" or some odd :|

    curl -4 "$url" --retry 50 -O -L --fail || echo_and_exit "unable to download $url"
    echo "unzipping $output_name ..."
    tar -xf "$output_name" || unzip "$output_name" || exit 1
    touch "$output_dir/unpacked.successfully" || exit 1
    rm "$output_name" || exit 1
  fi
}

generic_configure() {
  local extra_configure_options="$1"
  do_configure "--host=$host_target --prefix=$mingw_w64_x86_64_prefix --disable-shared --enable-static $extra_configure_options"
}

# params: url, optional "english name it will unpack to"
generic_download_and_make_and_install() {
  local url="$1"
  local english_name="$2"
  if [[ -z $english_name ]]; then
    english_name=$(basename $url | sed s/\.tar\.*//) # remove .tar.xx, take last part of url
  fi
  local extra_configure_options="$3"
  download_and_unpack_file $url $english_name
  cd $english_name || exit "unable to cd, may need to specify dir it will unpack to as parameter"
  generic_configure "$extra_configure_options"
  do_make_and_make_install
  cd ..
}

do_git_checkout_and_make_install() {
  local url=$1
  local git_checkout_name=$(basename $url | sed s/\.git/_git/) # http://y/abc.git -> abc_git
  do_git_checkout $url $git_checkout_name
  cd $git_checkout_name
    generic_configure_make_install
  cd ..
}

generic_configure_make_install() {
  if [ $# -gt 0 ]; then
    echo "cant pass parameters to this method today, they'd be a bit ambiguous"
    echo "The following arguments where passed: ${@}"
    exit 1
  fi
  generic_configure # no parameters, force myself to break it up if needed
  do_make_and_make_install
}

gen_ld_script() {
  lib=$mingw_w64_x86_64_prefix/lib/$1
  lib_s="$2"
  if [[ ! -f $mingw_w64_x86_64_prefix/lib/lib$lib_s.a ]]; then
    echo "Generating linker script $lib: $2 $3"
    mv -f $lib $mingw_w64_x86_64_prefix/lib/lib$lib_s.a
    echo "GROUP ( -l$lib_s $3 )" > $lib
  fi
}

build_dlfcn() {
  do_git_checkout https://github.com/dlfcn-win32/dlfcn-win32.git
  cd dlfcn-win32_git
    if [[ ! -f Makefile.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/-O3/-O2/" Makefile
    fi
    do_configure "--prefix=$mingw_w64_x86_64_prefix --cross-prefix=$cross_prefix" # rejects some normal cross compile options so custom here
    do_make_and_make_install
    gen_ld_script libdl.a dl_s -lpsapi # dlfcn-win32's 'README.md': "If you are linking to the static 'dl.lib' or 'libdl.a', then you would need to explicitly add 'psapi.lib' or '-lpsapi' to your linking command, depending on if MinGW is used."
  cd ..
}

build_bzip2() {
  download_and_unpack_file https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
  cd bzip2-1.0.8
    apply_patch file://$patch_dir/bzip2-1.0.8_brokenstuff.diff
    if [[ ! -f ./libbz2.a ]] || [[ -f $mingw_w64_x86_64_prefix/lib/libbz2.a && ! $(/usr/bin/env md5sum ./libbz2.a) = $(/usr/bin/env md5sum $mingw_w64_x86_64_prefix/lib/libbz2.a) ]]; then # Not built or different build installed
      do_make "$make_prefix_options libbz2.a"
      install -m644 bzlib.h $mingw_w64_x86_64_prefix/include/bzlib.h
      install -m644 libbz2.a $mingw_w64_x86_64_prefix/lib/libbz2.a
    else
      echo "Already made bzip2-1.0.8"
    fi
  cd ..
}

build_liblzma() {
  download_and_unpack_file https://sourceforge.net/projects/lzmautils/files/xz-5.2.5.tar.xz
  cd xz-5.2.5
    generic_configure "--disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls"
    do_make_and_make_install
  cd ..
}

build_zlib() {
  download_and_unpack_file https://github.com/madler/zlib/archive/v1.2.11.tar.gz zlib-1.2.11
  cd zlib-1.2.11
    local make_options
    if [[ $compiler_flavors == "native" ]]; then
      export CFLAGS="$CFLAGS -fPIC" # For some reason glib needs this even though we build a static library
    else
      export ARFLAGS=rcs # Native can't take ARFLAGS; https://stackoverflow.com/questions/21396988/zlib-build-not-configuring-properly-with-cross-compiler-ignores-ar
    fi
    do_configure "--prefix=$mingw_w64_x86_64_prefix --static"
    do_make_and_make_install "$make_prefix_options"
    if [[ $compiler_flavors == "native" ]]; then
      reset_cflags
    else
      unset ARFLAGS
    fi
  cd ..
}

build_iconv() {
  download_and_unpack_file https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.16.tar.gz
  cd libiconv-1.16
    generic_configure "--disable-nls"
    do_make "install-lib" # No need for 'do_make_install', because 'install-lib' already has install-instructions.
  cd ..
}

build_sdl2() {
  download_and_unpack_file https://www.libsdl.org/release/SDL2-2.0.12.tar.gz
  cd SDL2-2.0.12
    apply_patch file://$patch_dir/SDL2-2.0.12_lib-only.diff
    #apply_patch file://$patch_dir/sdl2.xinput.diff # mingw-w64 master needs it?
    if [[ ! -f configure.bak ]]; then
      sed -i.bak "s/ -mwindows//" configure # Allow ffmpeg to output anything to console.
    fi
    export CFLAGS="$CFLAGS -DDECLSPEC="  # avoid SDL trac tickets 939 and 282 [broken shared builds]
    if [[ $compiler_flavors == "native" ]]; then
      unset PKG_CONFIG_LIBDIR # Allow locally installed things for native builds; libpulse-dev is an important one otherwise no audio for most Linux
    fi
    generic_configure "--bindir=$mingw_bin_path"
    do_make_and_make_install
    if [[ $compiler_flavors == "native" ]]; then
      export PKG_CONFIG_LIBDIR=
    fi
    if [[ ! -f $mingw_bin_path/$host_target-sdl2-config ]]; then
      mv "$mingw_bin_path/sdl2-config" "$mingw_bin_path/$host_target-sdl2-config" # At the moment FFmpeg's 'configure' doesn't use 'sdl2-config', because it gives priority to 'sdl2.pc', but when it does, it expects 'i686-w64-mingw32-sdl2-config' in 'cross_compilers/mingw-w64-i686/bin'.
    fi
    reset_cflags
  cd ..
}

build_amd_amf_headers() {
  # was https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git too big
  # or https://github.com/DeadSix27/AMF smaller
  # but even smaller!
  do_git_checkout https://github.com/rdp/amf_headers.git amf_headers_git

  cd amf_headers_git
    if [ ! -f "already_installed" ]; then
      #rm -rf "./Thirdparty" # ?? plus too chatty...
      if [ ! -d "$mingw_w64_x86_64_prefix/include/AMF" ]; then
        mkdir -p "$mingw_w64_x86_64_prefix/include/AMF"
      fi
      cp -av "amf/public/include/." "$mingw_w64_x86_64_prefix/include/AMF" 
      touch "already_installed"
    fi
  cd ..
}

build_nv_headers() {
  do_git_checkout https://git.videolan.org/git/ffmpeg/nv-codec-headers.git
  cd nv-codec-headers_git
    do_make_install "PREFIX=$mingw_w64_x86_64_prefix" # just copies in headers
  cd ..
}

build_intel_quicksync_mfx() { # i.e. qsv, disableable via command line switch...
  do_git_checkout https://github.com/lu-zero/mfx_dispatch.git # lu-zero?? oh well seems somewhat supported...
  cd mfx_dispatch_git
    if [[ ! -f "configure" ]]; then
      autoreconf -fiv || exit 1
      automake --add-missing || exit 1
    fi
    if [[ $compiler_flavors == "native" && $OSTYPE != darwin* ]]; then
      unset PKG_CONFIG_LIBDIR # allow mfx_dispatch to use libva-dev or some odd...not sure for OS X so just disable it :)
      generic_configure_make_install
      export PKG_CONFIG_LIBDIR=
    else
      generic_configure_make_install
    fi
  cd ..
}

build_libleptonica() {
  build_libjpeg_turbo
  do_git_checkout https://github.com/DanBloomberg/leptonica.git leptonica_git 1.79.0
  cd leptonica_git
    export CPPFLAGS="-DOPJ_STATIC"
    generic_configure_make_install
    reset_cppflags
  cd ..
}

build_libtiff() {
  build_libjpeg_turbo # auto uses it?
  generic_download_and_make_and_install http://download.osgeo.org/libtiff/tiff-4.1.0.tar.gz
  sed -i.bak 's/-ltiff.*$/-ltiff -llzma -ljpeg -lz/' $PKG_CONFIG_PATH/libtiff-4.pc # static deps
} 

build_libtensorflow() {
  do_git_checkout_and_make_install https://github.com/tensorflow/tensorflow.git
}

build_glib() {
  export CPPFLAGS="$CPPFLAGS -DLIBXML_STATIC -liconv" # gettext build...
  generic_download_and_make_and_install  https://ftp.gnu.org/pub/gnu/gettext/gettext-0.20.2.tar.gz
  reset_cppflags
  generic_download_and_make_and_install  https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz # also dep
  download_and_unpack_file https://gitlab.gnome.org/GNOME/glib/-/archive/2.64.3/glib-2.64.3.tar.gz
  cd glib-2.64.3
    apply_patch  file://$patch_dir/glib-2.64.3_mingw-static.patch -p1
    export CPPFLAGS="$CPPFLAGS -pthread -DGLIB_STATIC_COMPILATION"
    export CXXFLAGS="$CFLAGS" # Not certain this is needed, but it doesn't hurt
    export LDFLAGS="-L${mingw_w64_x86_64_prefix}/lib" # For some reason the frexp configure checks fail without this as math.h isn't found when cross-compiling; no negative impact for native builds
    local meson_options="--prefix=${mingw_w64_x86_64_prefix} --libdir=${mingw_w64_x86_64_prefix}/lib --buildtype=release --strip --default-library=static -Dinternal_pcre=true -Dforce_posix_threads=true . build"
    if [[ $compiler_flavors != "native" ]]; then
      get_local_meson_cross_with_propeties # Need to add flags to meson properties; otherwise ran into some issues
      meson_options+=" --cross-file=meson-cross.mingw.txt"
    fi
    do_meson "$meson_options"
    do_ninja_and_ninja_install
    if [[ $compiler_flavors == "native" ]]; then
      sed -i.bak 's/-lglib-2.0.*$/-lglib-2.0 -pthread -lm -liconv/' $PKG_CONFIG_PATH/glib-2.0.pc
    else
      sed -i.bak 's/-lglib-2.0.*$/-lglib-2.0 -lintl -pthread -lws2_32 -lwinmm -lm -liconv -lole32/' $PKG_CONFIG_PATH/glib-2.0.pc
    fi
    reset_cppflags
    unset CXXFLAGS
    unset LDFLAGS
  cd ..
}

build_lensfun() {
  build_glib
  download_and_unpack_file https://sourceforge.net/projects/lensfun/files/0.3.95/lensfun-0.3.95.tar.gz
  cd lensfun-0.3.95
    export CMAKE_STATIC_LINKER_FLAGS='-lws2_32 -pthread'
    do_cmake "-DBUILD_STATIC=on -DCMAKE_INSTALL_DATAROOTDIR=$mingw_w64_x86_64_prefix"
    do_make
    do_make_install
    sed -i.bak 's/-llensfun/-llensfun -lstdc++/' "$PKG_CONFIG_PATH/lensfun.pc"
    unset CMAKE_STATIC_LINKER_FLAGS
  cd ..
}

build_libtesseract() {
  build_libtiff # no disable configure option for this in tesseract? odd...
  build_libleptonica
  do_git_checkout https://github.com/tesseract-ocr/tesseract.git tesseract_git 4.1.1
  cd tesseract_git
    if [[ $compiler_flavors != "native"  ]]; then
      apply_patch file://$patch_dir/tesseract-4.1.1_mingw-std-threads.patch
      generic_configure "--disable-openmp"
      do_make_and_make_install
      sed -i.bak 's/-ltesseract.*$/-ltesseract -lstdc++ -lws2_32 -llept -ltiff -llzma -ljpeg -lz/' $PKG_CONFIG_PATH/tesseract.pc # why does it needs winsock? LOL plus all of libtiff's <sigh>
    else
      generic_configure_make_install
      sed -i.bak 's/-ltesseract.*$/-ltesseract -lstdc++ -llept -ltiff -llzma -ljpeg -lz -lgomp/' $PKG_CONFIG_PATH/tesseract.pc # see above, gomp for linux native
    fi
  cd ..
}

build_libzimg() {
  do_git_checkout https://github.com/sekrit-twc/zimg.git zimg_git
  cd zimg_git
    generic_configure_make_install
  cd ..
}

build_libopenjpeg() {
  do_git_checkout https://github.com/uclouvain/openjpeg.git # basically v2.3+ 
  cd openjpeg_git
    do_cmake_and_install "-DBUILD_CODEC=0"
  cd ..
}

build_glew() {
  download_and_unpack_file https://sourceforge.net/projects/glew/files/glew/2.2.0/glew-2.2.0.tgz glew-2.2.0
  cd glew-2.2.0/build
    local cmake_params=""
    if [[ $compiler_flavors != "native" ]]; then
      cmake_params+=" -DWIN32=1"
    fi
    do_cmake_from_build_dir ./cmake "$cmake_params" # "-DWITH_FFMPEG=0 -DOPENCV_GENERATE_PKGCONFIG=1 -DHAVE_DSHOW=0"
    do_make_and_make_install
  cd ../..
}

build_glfw() {
  download_and_unpack_file https://github.com/glfw/glfw/releases/download/3.3.2/glfw-3.3.2.zip glfw-3.3.2
  cd glfw-3.3.2
    do_cmake_and_install
  cd ..
}

build_libpng() {
  do_git_checkout https://github.com/glennrp/libpng.git
  cd libpng_git
    generic_configure
    do_make_and_make_install
  cd ..
}

build_libwebp() {
  do_git_checkout https://chromium.googlesource.com/webm/libwebp.git
  cd libwebp_git
    export LIBPNG_CONFIG="$mingw_w64_x86_64_prefix/bin/libpng-config --static" # LibPNG somehow doesn't get autodetected.
    generic_configure "--disable-wic"
    do_make_and_make_install
    unset LIBPNG_CONFIG
  cd ..
}

build_harfbuzz() {
  local new_build=false
  do_git_checkout https://github.com/harfbuzz/harfbuzz.git harfbuzz_git
  if [ ! -f harfbuzz_git/already_done_harf ]; then # Not done or new master, so build
    new_build=true
  fi

  # basically gleaned from https://gist.github.com/roxlu/0108d45308a0434e27d4320396399153
  build_freetype "--without-harfbuzz" $new_build # Check for new freetype or force rebuild if needed
  local new_freetype=$?
  if $new_build || [ $new_freetype = 0 ]; then # 0 is true
    rm -f harfbuzz_git/already* # Force rebuilding in case only freetype has changed
    # cmake no .pc file so use configure :|
    cd harfbuzz_git
      if [ ! -f configure ]; then
        ./autogen.sh # :|
      fi
      export LDFLAGS=-lpthread # :|
      generic_configure "--with-freetype=yes --with-fontconfig=no --with-icu=no" # no fontconfig, don't want another circular what? icu is #372
      unset LDFLAGS
      do_make_and_make_install
    cd ..

    build_freetype "--with-harfbuzz" true # with harfbuzz now...
    touch harfbuzz_git/already_done_harf
    echo "Done harfbuzz"
  else
    echo "Already done harfbuzz"
  fi
  sed -i.bak 's/-lfreetype.*/-lfreetype -lharfbuzz -lpthread/' "$PKG_CONFIG_PATH/freetype2.pc" # for some reason it lists harfbuzz as Requires.private only??
  sed -i.bak 's/-lharfbuzz.*/-lharfbuzz -lfreetype/' "$PKG_CONFIG_PATH/harfbuzz.pc" # does anything even use this?
  sed -i.bak 's/libfreetype.la -lbz2/libfreetype.la -lharfbuzz -lbz2/' "${mingw_w64_x86_64_prefix}/lib/libfreetype.la" # XXX what the..needed?
  sed -i.bak 's/libfreetype.la -lbz2/libfreetype.la -lharfbuzz -lbz2/' "${mingw_w64_x86_64_prefix}/lib/libharfbuzz.la"
}

build_freetype() {
  local force_build=$2
  local new_build=1
  if [[ ! -f freetype-2.10.2/already_done_freetype || $force_build = true ]]; then
    download_and_unpack_file https://sourceforge.net/projects/freetype/files/freetype2/2.10.2/freetype-2.10.2.tar.xz
    rm -f freetype-2.10.2/already*
    cd freetype-2.10.2
        # harfbuzz autodetect :|
        generic_configure "--with-bzip2 $1"
        do_make_and_make_install
        touch already_done_freetype
        new_build=0
    cd ..
  fi
  return $new_build # Give caller a way to know if a new build was done
}

build_libxml2() {
  download_and_unpack_file http://xmlsoft.org/sources/libxml2-2.9.10.tar.gz libxml2-2.9.10
  cd libxml2-2.9.10
    generic_configure "--with-ftp=no --with-http=no --with-python=no"
    do_make_and_make_install
  cd ..
}

build_libvmaf() {
  do_git_checkout https://github.com/Netflix/vmaf.git vmaf_git v1.5.1
  cd vmaf_git
    apply_patch file://$patch_dir/libvmaf.various-1.5.1.patch -p1
    cd libvmaf
    export CFLAGS="$CFLAGS -pthread"
    export CXXFLAGS="$CFLAGS -pthread"
    export LDFLAGS="-pthread" # Needed here too for some reason
    mkdir build
    local meson_options="--prefix=${mingw_w64_x86_64_prefix} --libdir=${mingw_w64_x86_64_prefix}/lib --buildtype=release --strip --default-library=static . build"
    if [[ $compiler_flavors != "native" ]]; then
      get_local_meson_cross_with_propeties # Need to add flags to meson properties; otherwise ran into some issues
      meson_options+=" --cross-file=meson-cross.mingw.txt"
    fi
    do_meson "$meson_options"
    do_ninja_and_ninja_install
    reset_cflags
    unset CXXFLAGS
    unset LDFLAGS
    if [[ $compiler_flavors == "native" ]]; then # Can't find a way to not build these; meson is already set to --default-library=static but it still builds both
      rm -f ${mingw_w64_x86_64_prefix}/lib/libvmaf.so
    else
      rm -f ${mingw_w64_x86_64_prefix}/lib/libvmaf.dll.a
    fi
    sed -i.bak "s/Libs.private.*/& -lstdc++/" "$PKG_CONFIG_PATH/libvmaf.pc" # .pc is still broken
  cd ../..
}

build_fontconfig() {
  download_and_unpack_file https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.13.92.tar.xz
  cd fontconfig-2.13.92
    #export CFLAGS= # compile fails with -march=sandybridge ... with mingw 4.0.6 at least ...
    generic_configure "--enable-iconv --enable-libxml2 --disable-docs --with-libiconv" # Use Libxml2 instead of Expat.
    do_make_and_make_install
    #reset_cflags
  cd ..
}

build_gmp() {
  download_and_unpack_file https://gmplib.org/download/gmp/gmp-6.2.0.tar.xz
  cd gmp-6.2.0
    #export CC_FOR_BUILD=/usr/bin/gcc # Are these needed?
    #export CPP_FOR_BUILD=usr/bin/cpp
    generic_configure "ABI=$bits_target"
    #unset CC_FOR_BUILD
    #unset CPP_FOR_BUILD
    do_make_and_make_install
  cd ..
}

build_librtmfp() {
  # needs some version of openssl...
  # build_openssl-1.0.2 # fails OS X 
  build_openssl-1.1.1
  do_git_checkout https://github.com/MonaSolutions/librtmfp.git
  cd librtmfp_git/include/Base
    do_git_checkout https://github.com/meganz/mingw-std-threads.git mingw-std-threads # our g++ apparently doesn't have std::mutex baked in...weird...this replaces it...
  cd ../../..
  cd librtmfp_git
    if [[ $compiler_flavors != "native" ]]; then
      apply_patch file://$patch_dir/rtmfp.static.cross.patch -p1 # works e48efb4f
      apply_patch file://$patch_dir/rtmfp_capitalization.diff -p1 # cross for windows needs it if on linux...
      apply_patch file://$patch_dir/librtmfp_xp.diff.diff -p1 # cross for windows needs it if on linux...
    else
      apply_patch file://$patch_dir/rtfmp.static.make.patch -p1
    fi
    do_make "$make_prefix_options GPP=${cross_prefix}g++"
    do_make_install "prefix=$mingw_w64_x86_64_prefix PKGCONFIGPATH=$PKG_CONFIG_PATH"
    if [[ $compiler_flavors == "native" ]]; then
      sed -i.bak 's/-lrtmfp.*/-lrtmfp -lstdc++/' "$PKG_CONFIG_PATH/librtmfp.pc"
    else
      sed -i.bak 's/-lrtmfp.*/-lrtmfp -lstdc++ -lws2_32 -liphlpapi/' "$PKG_CONFIG_PATH/librtmfp.pc"
    fi
  cd ..
}

build_libnettle() {
  download_and_unpack_file https://ftp.gnu.org/gnu/nettle/nettle-3.6.tar.gz
  cd nettle-3.6
    local config_options="--disable-openssl --disable-documentation" # in case we have both gnutls and openssl, just use gnutls [except that gnutls uses this so...huh?
    if [[ $compiler_flavors == "native" ]]; then
      config_options+=" --libdir=${mingw_w64_x86_64_prefix}/lib" # Otherwise native builds install to /lib32 or /lib64 which gnutls doesn't find
    fi
    generic_configure "$config_options" # in case we have both gnutls and openssl, just use gnutls [except that gnutls uses this so...huh? https://github.com/rdp/ffmpeg-windows-build-helpers/issues/25#issuecomment-28158515
    do_make_and_make_install # What's up with "Configured with: ... --with-gmp=/cygdrive/d/ffmpeg-windows-build-helpers-master/native_build/windows/ffmpeg_local_builds/sandbox/cross_compilers/pkgs/gmp/gmp-6.1.2-i686" in 'config.log'? Isn't the 'gmp-6.1.2' above being used?
  cd ..
}

build_unistring() {
  generic_download_and_make_and_install https://ftp.gnu.org/gnu/libunistring/libunistring-0.9.10.tar.xz
}

build_libidn2() {
  generic_download_and_make_and_install https://ftp.gnu.org/gnu/libidn/libidn2-2.3.0.tar.gz
}

build_gnutls() {
  download_and_unpack_file https://www.gnupg.org/ftp/gcrypt/gnutls/v3.6/gnutls-3.6.14.tar.xz
  cd gnutls-3.6.14
    # --disable-cxx don't need the c++ version, in an effort to cut down on size... XXXX test size difference...
    # --enable-local-libopts to allow building with local autogen installed,
    # --disable-guile is so that if it finds guile installed (cygwin did/does) it won't try and link/build to it and fail...
    # libtasn1 is some dependency, appears provided is an option [see also build_libnettle]
    # pks #11 hopefully we don't need kit
    generic_configure "--disable-doc --disable-tools --disable-cxx --disable-tests --disable-gtk-doc-html --disable-libdane --disable-nls --enable-local-libopts --disable-guile --with-included-libtasn1 --without-p11-kit"
    do_make_and_make_install
    if [[ $compiler_flavors != "native"  ]]; then
      # libsrt doesn't know how to use its pkg deps :| https://github.com/Haivision/srt/issues/565
      sed -i.bak 's/-lgnutls.*/-lgnutls -lcrypt32 -lnettle -lhogweed -lgmp -lidn2 -liconv -lunistring/' "$PKG_CONFIG_PATH/gnutls.pc" 
      if [[ $OSTYPE == darwin* ]]; then
        sed -i.bak 's/-lgnutls.*/-lgnutls -framework Security -framework Foundation/' "$PKG_CONFIG_PATH/gnutls.pc" 
      fi
    fi
  cd ..
}

build_openssl-1.0.2() {
  download_and_unpack_file https://www.openssl.org/source/openssl-1.0.2p.tar.gz
  cd openssl-1.0.2p
    apply_patch file://$patch_dir/openssl-1.0.2l_lib-only.diff
    export CC="${cross_prefix}gcc"
    export AR="${cross_prefix}ar"
    export RANLIB="${cross_prefix}ranlib"
    local config_options="--prefix=$mingw_w64_x86_64_prefix zlib "
    if [ "$1" = "dllonly" ]; then
      config_options+="shared "
    else
      config_options+="no-shared no-dso "
    fi
    if [ "$bits_target" = "32" ]; then
      config_options+="mingw" # Build shared libraries ('libeay32.dll' and 'ssleay32.dll') if "dllonly" is specified.
      local arch=x86
    else
      config_options+="mingw64" # Build shared libraries ('libeay64.dll' and 'ssleay64.dll') if "dllonly" is specified.
      local arch=x86_64
    fi
    do_configure "$config_options" ./Configure
    if [[ ! -f Makefile_1 ]]; then
      sed -i_1 "s/-O3/-O2/" Makefile # Change CFLAGS (OpenSSL's 'Configure' already creates a 'Makefile.bak').
    fi
    if [ "$1" = "dllonly" ]; then
      do_make "build_libs"

      mkdir -p $cur_dir/redist # Strip and pack shared libraries.
      archive="$cur_dir/redist/openssl-${arch}-v1.0.2l.7z"
      if [[ ! -f $archive ]]; then
        for sharedlib in *.dll; do
          ${cross_prefix}strip $sharedlib
        done
        sed "s/$/\r/" LICENSE > LICENSE.txt
        7z a -mx=9 $archive *.dll LICENSE.txt && rm -f LICENSE.txt
      fi
    else
      do_make_and_make_install
    fi
    unset CC
    unset AR
    unset RANLIB
  cd ..
}

build_openssl-1.1.1() {
  download_and_unpack_file https://www.openssl.org/source/openssl-1.1.1.tar.gz
  cd openssl-1.1.1
    export CC="${cross_prefix}gcc"
    export AR="${cross_prefix}ar"
    export RANLIB="${cross_prefix}ranlib"
    local config_options="--prefix=$mingw_w64_x86_64_prefix zlib "
    if [ "$1" = "dllonly" ]; then
      config_options+="shared no-engine "
    else
      config_options+="no-shared no-dso no-engine "
    fi
    if [[ `uname` =~ "5.1" ]] || [[ `uname` =~ "6.0" ]]; then
      config_options+="no-async " # "Note: on older OSes, like CentOS 5, BSD 5, and Windows XP or Vista, you will need to configure with no-async when building OpenSSL 1.1.0 and above. The configuration system does not detect lack of the Posix feature on the platforms." (https://wiki.openssl.org/index.php/Compilation_and_Installation)
    fi
    if [[ $compiler_flavors == "native" ]]; then
      if [[ $OSTYPE == darwin* ]]; then
        config_options+="darwin64-x86_64-cc "
      else
        config_options+="linux-generic64 " 
      fi
      local arch=native
    elif [ "$bits_target" = "32" ]; then
      config_options+="mingw" # Build shared libraries ('libcrypto-1_1.dll' and 'libssl-1_1.dll') if "dllonly" is specified.
      local arch=x86
    else
      config_options+="mingw64" # Build shared libraries ('libcrypto-1_1-x64.dll' and 'libssl-1_1-x64.dll') if "dllonly" is specified.
      local arch=x86_64
    fi
    do_configure "$config_options" ./Configure
    if [[ ! -f Makefile.bak ]]; then # Change CFLAGS.
      sed -i.bak "s/-O3/-O2/" Makefile
    fi
    do_make "build_libs"
    if [ "$1" = "dllonly" ]; then
      mkdir -p $cur_dir/redist # Strip and pack shared libraries.
      archive="$cur_dir/redist/openssl-${arch}-v1.1.0f.7z"
      if [[ ! -f $archive ]]; then
        for sharedlib in *.dll; do
          ${cross_prefix}strip $sharedlib
        done
        sed "s/$/\r/" LICENSE > LICENSE.txt
        7z a -mx=9 $archive *.dll LICENSE.txt && rm -f LICENSE.txt
      fi
    else
      do_make_install "" "install_dev"
    fi
    unset CC
    unset AR
    unset RANLIB
  cd ..
}

build_libogg() {
  do_git_checkout https://github.com/xiph/ogg.git
  cd ogg_git
    generic_configure_make_install
  cd ..
}

build_libvorbis() {
  do_git_checkout https://github.com/xiph/vorbis.git
  cd vorbis_git
    generic_configure "--disable-docs --disable-examples --disable-oggtest"
    do_make_and_make_install
  cd ..
}

build_libopus() {
  do_git_checkout https://github.com/xiph/opus.git
  cd opus_git
    generic_configure "--disable-doc --disable-extra-programs --disable-stack-protector"
    do_make_and_make_install
  cd ..
}

build_libspeexdsp() {
  do_git_checkout https://github.com/xiph/speexdsp.git
  cd speexdsp_git
    generic_configure "--disable-examples"
    do_make_and_make_install
  cd ..
}

build_libspeex() {
  do_git_checkout https://github.com/xiph/speex.git
  cd speex_git
    export SPEEXDSP_CFLAGS="-I$mingw_w64_x86_64_prefix/include"
    export SPEEXDSP_LIBS="-L$mingw_w64_x86_64_prefix/lib -lspeexdsp" # 'configure' somehow can't find SpeexDSP with 'pkg-config'.
    generic_configure "--disable-binaries" # If you do want the libraries, then 'speexdec.exe' needs 'LDFLAGS=-lwinmm'.
    do_make_and_make_install
    unset SPEEXDSP_CFLAGS
    unset SPEEXDSP_LIBS
  cd ..
}

build_libtheora() {
  do_git_checkout https://github.com/xiph/theora.git
  cd theora_git
    generic_configure "--disable-doc --disable-spec --disable-oggtest --disable-vorbistest --disable-examples --disable-asm" # disable asm: avoid [theora @ 0x1043144a0]error in unpack_block_qpis in 64 bit... [OK OS X 64 bit tho...]
    do_make_and_make_install
  cd ..
}

build_libsndfile() {
  do_git_checkout https://github.com/erikd/libsndfile.git
  cd libsndfile_git
    generic_configure "--disable-sqlite --disable-external-libs --disable-full-suite"
    do_make_and_make_install
    if [ "$1" = "install-libgsm" ]; then
      if [[ ! -f $mingw_w64_x86_64_prefix/lib/libgsm.a ]]; then
        install -m644 src/GSM610/gsm.h $mingw_w64_x86_64_prefix/include/gsm.h || exit 1
        install -m644 src/GSM610/.libs/libgsm.a $mingw_w64_x86_64_prefix/lib/libgsm.a || exit 1
      else
        echo "already installed GSM 6.10 ..."
      fi
    fi
  cd ..
}

build_lame() {
  do_svn_checkout https://svn.code.sf.net/p/lame/svn/trunk/lame lame_svn
  cd lame_svn
    sed -i.bak "1{/^\xef\xbb\xbf$/d}" libmp3lame/i386/nasm.h # Remove a UTF-8 BOM that breaks nasm if it's still there; should be fixed in trunk eventually https://sourceforge.net/p/lame/patches/81/
    generic_configure "--enable-nasm"
    do_make_and_make_install
  cd ..
}

build_twolame() {
  do_git_checkout https://github.com/njh/twolame.git
  cd twolame_git
    if [[ ! -f Makefile.am.bak ]]; then # Library only, front end refuses to build for some reason with git master
      sed -i.bak "/^SUBDIRS/s/ frontend.*//" Makefile.am || exit 1 
    fi
    cpu_count=1 # maybe can't handle it http://betterlogic.com/roger/2017/07/mp3lame-woe/ comments
    generic_configure_make_install
    cpu_count=$original_cpu_count
  cd ..
}

build_fdk-aac() {
  do_git_checkout https://github.com/mstorsjo/fdk-aac.git
  cd fdk-aac_git
    if [[ ! -f "configure" ]]; then
      autoreconf -fiv || exit 1
    fi
    generic_configure_make_install
  cd ..
}

build_libopencore() {
  generic_download_and_make_and_install https://sourceforge.net/projects/opencore-amr/files/opencore-amr/opencore-amr-0.1.5.tar.gz
  generic_download_and_make_and_install https://sourceforge.net/projects/opencore-amr/files/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz
}

build_libilbc() {
  do_git_checkout https://github.com/TimothyGu/libilbc.git
  cd libilbc_git
    generic_configure_make_install
  cd ..
}

build_libmodplug() {
  do_git_checkout https://github.com/Konstanty/libmodplug.git
  cd libmodplug_git
    sed -i.bak 's/__declspec(dllexport)//' "$mingw_w64_x86_64_prefix/include/libmodplug/modplug.h" #strip DLL import/export directives
    sed -i.bak 's/__declspec(dllimport)//' "$mingw_w64_x86_64_prefix/include/libmodplug/modplug.h"
    if [[ ! -f "configure" ]]; then
      autoreconf -fiv || exit 1
      automake --add-missing || exit 1
    fi
    generic_configure_make_install # or could use cmake I guess
  cd ..
}

build_libgme() {
  # do_git_checkout https://bitbucket.org/mpyne/game-music-emu.git
  download_and_unpack_file https://bitbucket.org/mpyne/game-music-emu/downloads/game-music-emu-0.6.3.tar.xz
  cd game-music-emu-0.6.3
    do_cmake_and_install "-DENABLE_UBSAN=0"
  cd ..
}

build_mingw_std_threads() {
  do_git_checkout https://github.com/meganz/mingw-std-threads.git # it needs std::mutex too :|
  cd mingw-std-threads_git
    cp *.h "$mingw_w64_x86_64_prefix/include"
  cd ..
}

build_opencv() {
  build_mingw_std_threads
  #do_git_checkout https://github.com/opencv/opencv.git # too big :|
  download_and_unpack_file https://github.com/opencv/opencv/archive/3.4.5.zip opencv-3.4.5
  mkdir -p opencv-3.4.5/build
  cd opencv-3.4.5
     apply_patch file://$patch_dir/opencv.detection_based.patch
  cd ..
  cd opencv-3.4.5/build
    # could do more here, it seems to think it needs its own internal libwebp etc...
    cpu_count=1
    do_cmake_from_build_dir .. "-DWITH_FFMPEG=0 -DOPENCV_GENERATE_PKGCONFIG=1 -DHAVE_DSHOW=0" # https://stackoverflow.com/q/40262928/32453, no pkg config by default on "windows", who cares ffmpeg 
    do_make_and_make_install
    cp unix-install/opencv.pc $PKG_CONFIG_PATH
    cpu_count=$original_cpu_count
  cd ../..
}

build_facebooktransform360() {
  build_opencv
  do_git_checkout https://github.com/facebook/transform360.git
  cd transform360_git
    apply_patch file://$patch_dir/transform360.pi.diff -p1
  cd ..
  cd transform360_git/Transform360
    do_cmake ""
    sed -i.bak "s/isystem/I/g" CMakeFiles/Transform360.dir/includes_CXX.rsp # weird stdlib.h error
    do_make_and_make_install
  cd ../.. 
}

build_libbluray() {
  unset JDK_HOME # #268 was causing failure
  do_git_checkout https://code.videolan.org/videolan/libbluray.git
  cd libbluray_git
    if [[ ! -d .git/modules ]]; then
      git submodule update --init --remote # For UDF support [default=enabled], which strangely enough is in another repository.
    else
      local local_git_version=`git --git-dir=.git/modules/contrib/libudfread rev-parse HEAD`
      local remote_git_version=`git ls-remote -h https://code.videolan.org/videolan/libudfread.git | sed "s/[[:space:]].*//"`
      if [[ "$local_git_version" != "$remote_git_version" ]]; then
        echo "doing git clean -f"
        git clean -f # Throw away local changes; 'already_*' in this case.
      
