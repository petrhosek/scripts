# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Shell library for functions and initialization private to
# build_image, and not specific to any particular kind of image.
#
# TODO(jrbarnette):  There's nothing holding this code together in
# one file aside from its lack of anywhere else to go.  Probably,
# this file should get broken up or otherwise reorganized.

# Use canonical path since some tools (e.g. mount) do not like symlinks.
# Append build attempt to output directory.
if [ -z "${FLAGS_version}" ]; then
  IMAGE_SUBDIR="${FLAGS_group}-${COREOS_VERSION_STRING}-a${FLAGS_build_attempt}"
else
  IMAGE_SUBDIR="${FLAGS_group}-${FLAGS_version}"
fi
BUILD_DIR="${FLAGS_output_root}/${BOARD}/${IMAGE_SUBDIR}"
OUTSIDE_OUTPUT_DIR="../build/images/${BOARD}/${IMAGE_SUBDIR}"

set_build_symlinks() {
    local build=$(basename ${BUILD_DIR})
    local link
    for link in "$@"; do
        local path="${FLAGS_output_root}/${BOARD}/${link}"
        ln -sfT "${build}" "${path}"
    done
}

cleanup_mounts() {
  echo "Cleaning up mounts"
  "${BUILD_LIBRARY_DIR}/disk_util" umount "$1" || true
}

delete_prompt() {
  echo "An error occurred in your build so your latest output directory" \
    "is invalid."

  # Only prompt if both stdin and stdout are a tty. If either is not a tty,
  # then the user may not be present, so we shouldn't bother prompting.
  if [ -t 0 -a -t 1 -a "${USER}" != 'chrome-bot' ]; then
    read -p "Would you like to delete the output directory (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character.
  else
    SURE="y"
    echo "Running in non-interactive mode so deleting output directory."
  fi
  if [ "${SURE}" == "y" ] ; then
    sudo rm -rf "${BUILD_DIR}"
    echo "Deleted ${BUILD_DIR}"
  else
    echo "Not deleting ${BUILD_DIR}."
  fi
}

generate_update() {
  local image_name="$1"
  local disk_layout="$2"
  local update_prefix="${image_name%_image.bin}_update"
  local update="${BUILD_DIR}/${update_prefix}"
  local devkey="/usr/share/update_engine/update-payload-key.key.pem"

  echo "Generating update payload, signed with a dev key"
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
    extract "${BUILD_DIR}/${image_name}" "USR-A" "${update}.bin"
  delta_generator -private_key "${devkey}" \
    -new_image "${update}.bin" -out_file "${update}.gz"
  delta_generator -private_key "${devkey}" \
    -in_file "${update}.gz" -out_metadata "${update}.meta"

  info "Generating update tools zip"
  # Make sure some vars this script needs are exported
  export REPO_MANIFESTS_DIR SCRIPTS_DIR
  "${BUILD_LIBRARY_DIR}/generate_au_zip.py" \
    --output-dir "${BUILD_DIR}" --zip-name "${update_prefix}.zip"

  upload_image -d "${update}.DIGESTS" "${update}".{bin,gz,meta,zip}
}

# Basic command to emerge binary packages into the target image.
# Arguments to this command are passed as addition options/arguments
# to the basic emerge command.
emerge_to_image() {
  local root_fs_dir="$1"; shift
  local mask="${INSTALL_MASK:-$(portageq-$BOARD envvar PROD_INSTALL_MASK)}"
  test -n "$mask" || die "PROD_INSTALL_MASK not defined"

  local emerge_cmd
  if [[ "${FLAGS_fast}" -eq "${FLAGS_TRUE}" ]]; then
    emerge_cmd="$GCLIENT_ROOT/chromite/bin/parallel_emerge --board=$BOARD"
  else
    emerge_cmd="emerge-$BOARD"
  fi
  emerge_cmd+=" --root-deps=rdeps --usepkgonly -v"

  if [[ $FLAGS_jobs -ne -1 ]]; then
    emerge_cmd+=" --jobs=$FLAGS_jobs"
  fi

  sudo -E INSTALL_MASK="$mask" ${emerge_cmd} --root="${root_fs_dir}" "$@"

  # Make sure profile.env and ld.so.cache has been generated
  sudo -E ROOT="${root_fs_dir}" env-update
}

# Usage: systemd_enable /root default.target something.service
# Or: systemd_enable /root default.target some@.service some@thing.service
systemd_enable() {
  local root_fs_dir="$1"
  local target="$2"
  local unit_file="$3"
  local unit_alias="${4:-$3}"
  local wants_dir="${root_fs_dir}/usr/lib/systemd/system/${target}.wants"

  sudo mkdir -p "${wants_dir}"
  sudo ln -sf "../${unit_file}" "${wants_dir}/${unit_alias}"
}

start_image() {
  local image_name="$1"
  local disk_layout="$2"
  local root_fs_dir="$3"

  local disk_img="${BUILD_DIR}/${image_name}"

  info "Using image type ${disk_layout}"
  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      format "${disk_img}"

  "${BUILD_LIBRARY_DIR}/disk_util" --disk_layout="${disk_layout}" \
      mount "${disk_img}" "${root_fs_dir}"
  trap "cleanup_mounts '${root_fs_dir}' && delete_prompt" EXIT

  # First thing first, install baselayout with USE=build to create a
  # working directory tree. Don't use binpkgs due to the use flag change.
  sudo -E USE=build "emerge-${BOARD}" --root="${root_fs_dir}" \
      --usepkg=n --buildpkg=n --oneshot --quiet --nodeps sys-apps/baselayout

  # FIXME(marineam): Work around glibc setting EROOT=$ROOT
  # https://bugs.gentoo.org/show_bug.cgi?id=473728#c12
  sudo mkdir -p "${root_fs_dir}/etc/ld.so.conf.d"
}

finish_image() {
  local disk_layout="$1"
  local root_fs_dir="$2"
  local update_group="$3"

  # Record directories installed to the state partition.
  # Explicitly ignore entries covered by existing configs.
  local tmp_ignore=$(awk '/^[dDfFL]/ {print "--ignore=" $2}' \
      "${root_fs_dir}"/usr/lib/tmpfiles.d/*.conf)
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_var.conf" \
      ${tmp_ignore} "${root_fs_dir}/var"
  sudo "${BUILD_LIBRARY_DIR}/gen_tmpfiles.py" --root="${root_fs_dir}" \
      --output="${root_fs_dir}/usr/lib/tmpfiles.d/base_image_etc.conf" \
      ${tmp_ignore} "${root_fs_dir}/etc"

  # Set /etc/lsb-release on the image.
  "${BUILD_LIBRARY_DIR}/set_lsb_release" \
    --root="${root_fs_dir}" \
    --group="${update_group}" \
    --board="${BOARD}"

  # Only configure bootloaders if there is a boot partition
  if mountpoint -q "${root_fs_dir}"/boot/efi; then
    ${BUILD_LIBRARY_DIR}/configure_bootloaders.sh \
      --arch=${ARCH} \
      --disk_layout="${disk_layout}" \
      --boot_dir="${root_fs_dir}"/usr/boot \
      --esp_dir="${root_fs_dir}"/boot/efi \
      --boot_args="${FLAGS_boot_args}"
  fi

  if [[ -n "${FLAGS_developer_data}" ]]; then
    local data_path="/usr/share/coreos/developer_data"
    local unit_path="usr-share-coreos-developer_data"
    sudo cp "${FLAGS_developer_data}" "${root_fs_dir}/${data_path}"
    systemd_enable "${root_fs_dir}" user-config.target \
        "user-cloudinit@.path" "user-cloudinit@${unit_path}.path"
  fi

  # Zero all fs free space to make it more compressible so auto-update
  # payloads become smaller, not fatal since it won't work on linux < 3.2
  sudo fstrim "${root_fs_dir}" || true
  if mountpoint -q "${root_fs_dir}/usr"; then
    sudo fstrim "${root_fs_dir}/usr" || true
  fi

  cleanup_mounts "${root_fs_dir}"
  trap - EXIT
}
