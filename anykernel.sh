### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=Kyuofox-Kernel
kernel.maintainer=Made by Github.com/Kyuofox
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=Redmi Note 12 Turbo
device.name2=POCO F5
device.name3=marble
device.name4=marblein
device.name5=
supported.versions=15
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
#boot_attributes() {
#set_perm_recursive 0 0 755 644 $RAMDISK/*;
#set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
#} # end attributes

# boot shell variables
BLOCK=boot;
BOOT_SUFFIX="$(getprop ro.boot.slot_suffix)";
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
split_boot; # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

## vendor_dlkm install
extract_erofs() {
	local img_file=$1
	local out_dir=$2

	${BIN}/extract.erofs -i "$img_file" -x -T8 -o "$out_dir" &> /dev/null
}

mkfs_erofs() {
	local work_dir=$1
	local out_file=$2
	local partition_name

	partition_name=$(basename "$work_dir")

	${BIN}/mkfs.erofs \
		--mount-point "/${partition_name}" \
		--fs-config-file "${work_dir}/../config/${partition_name}_fs_config" \
		--file-contexts  "${work_dir}/../config/${partition_name}_file_contexts" \
		-z lz4hc \
		"$out_file" "$work_dir"
}

is_mounted() { mount | grep -q " $1 "; }

get_size() {
	local _path=$1
	local _size

	if [ -d "$_path" ]; then
		du -bs $_path | awk '{print $1}'
		return
	fi
	if [ -b "$_path" ]; then
		_size=$(blockdev --getsize64 $_path) && {
			echo $_size
			return
		}
	fi
	wc -c < $_path
}

bytes_to_mb() {
	echo $1 | awk '{printf "%.1fM", $1 / 1024 / 1024}'
}

check_super_device_size() {
	# Check super device size
	local block_device_size block_device_size_lp

	block_device_size=$(get_size /dev/block/by-name/super) || \
		abort "! Failed to get super block device size (by blockdev)!"
	block_device_size_lp=$(${BIN}/lpdump 2>/dev/null | grep -E 'Size: [[:digit:]]+ bytes$' | head -n1 | awk '{print $2}') || \
		abort "! Failed to get super block device size (by lpdump)!"
	ui_print "- Super block device size:"
	ui_print "  - Read by blockdev: $block_device_size"
	ui_print "  - Read by lpdump: $block_device_size_lp"
	[ "$block_device_size" == "9663676416" ] && [ "$block_device_size_lp" == "9663676416" ] || \
		abort "! Super block device size mismatch!"
}

# Staging unmodified partition images
mkdir -p ${AKHOME}/_orig
cp ${AKHOME}/boot.img ${AKHOME}/_orig/boot.img

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
${BIN}/snapshotupdater_static dump &>/dev/null
rc=$?
if [ "$rc" != 0 ]; then
	ui_print " "
	ui_print "Cannot get snapshot status via snapshotupdater_static! rc=$rc."
	if ${BOOTMODE}; then
		ui_print "If you are installing the kernel in an app, try using another app."
		ui_print "Recommend KernelFlasher:"
		ui_print "  https://github.com/capntrips/KernelFlasher/releases"
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
snapshot_status=$(${BIN}/snapshotupdater_static dump 2>/dev/null | grep '^Update state:' | awk '{print $3}')
ui_print " "
ui_print "- Current snapshot state: $snapshot_status"
if [ "$snapshot_status" != "none" ]; then
	ui_print " "
	ui_print "Seems like you just installed a rom update."
	if [ "$snapshot_status" == "merging" ]; then
		ui_print "Please use the rom for a while to wait for"
		ui_print "the system to complete the snapshot merge."
		ui_print "It's also possible to use the \"Merge Snapshots\" feature"
		ui_print "in TWRP's Advanced menu to instantly merge snapshots."
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
unset rc snapshot_status

[ -f ${AKHOME}/Image.7z ] || abort "! Cannot found ${AKHOME}/Image.7z!"
ui_print " "
ui_print "- Unpacking kernel image..."
${BIN}/7za x ${AKHOME}/Image.7z -o${AKHOME}/ && [ -f ${AKHOME}/Image ] || abort "! Failed to unpack ${AKHOME}/Image.7z!"
rm ${AKHOME}/Image.7z

# Fix unable to mount image as read-write in recovery
$BOOTMODE || setenforce 0

ui_print " "
ui_print "- Unpacking kernel modules..."
modules_pkg=${AKHOME}/modules.7z
[ -f $modules_pkg ] || abort "! Cannot found ${modules_pkg}!"
${BIN}/7za x $modules_pkg -o${AKHOME}/ && [ -d ${AKHOME}/_vendor_boot_modules ] && [ -d ${AKHOME}/_vendor_dlkm_modules ] || \
	abort "! Failed to unpack ${modules_pkg}!"
unset modules_pkg

ui_print " "
if true; then  # I don't want to adjust the indentation of the code block below, so leave it as is.
	do_check_super_device_size=false

	# Dump vendor_dlkm partition image
	dd if=/dev/block/mapper/vendor_dlkm${SLOT} of=${AKHOME}/vendor_dlkm.img
	cp ${AKHOME}/vendor_dlkm.img ${AKHOME}/_orig/vendor_dlkm.img
	vendor_dlkm_block_size=$(get_size /dev/block/mapper/vendor_dlkm${SLOT})

	ui_print "- Unpacking /vendor_dlkm partition..."
	extract_vendor_dlkm_dir=${AKHOME}/_extract_vendor_dlkm
	mkdir -p $extract_vendor_dlkm_dir
	vendor_dlkm_is_ext4=false
	extract_erofs ${AKHOME}/vendor_dlkm.img $extract_vendor_dlkm_dir || vendor_dlkm_is_ext4=true
	sync

	if ${vendor_dlkm_is_ext4}; then
		ui_print "- /vendor_dlkm seems to be in ext4 file system."
		mount ${AKHOME}/vendor_dlkm.img $extract_vendor_dlkm_dir -o ro -t ext4 || \
			abort "! Unsupported file system!"
		vendor_dlkm_full_space=$(df -B1 | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $2}')
		vendor_dlkm_used_space=$(df -B1 | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $3}')
		vendor_dlkm_free_space=$(df -B1 | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $4}')
		vendor_dlkm_stock_modules_size=$(get_size ${extract_vendor_dlkm_dir}/lib/modules)
		ui_print "- /vendor_dlkm partition space:"
		ui_print "  - Total space: $(bytes_to_mb $vendor_dlkm_full_space)"
		ui_print "  - Used space:  $(bytes_to_mb $vendor_dlkm_used_space)"
		ui_print "  - Free space:  $(bytes_to_mb $vendor_dlkm_free_space)"
		umount $extract_vendor_dlkm_dir

		vendor_dlkm_new_modules_size=$(get_size ${AKHOME}/_vendor_dlkm_modules)
		vendor_dlkm_need_size=$((vendor_dlkm_used_space - vendor_dlkm_stock_modules_size + vendor_dlkm_new_modules_size + 10*1024*1024))
		if [ "$vendor_dlkm_need_size" -ge "$vendor_dlkm_full_space" ]; then
			# Resize vendor_dlkm image
			ui_print "- /vendor_dlkm partition does not have enough free space!"
			ui_print "- Trying to resize..."

			${BIN}/e2fsck -f -y ${AKHOME}/vendor_dlkm.img
			vendor_dlkm_resized_size=$(echo $vendor_dlkm_need_size | awk '{printf "%dM", ($1 / 1024 / 1024 + 1)}')
			${BIN}/resize2fs ${AKHOME}/vendor_dlkm.img $vendor_dlkm_resized_size || \
				abort "! Failed to resize vendor_dlkm image!"
			ui_print "- Resized vendor_dlkm.img size: ${vendor_dlkm_resized_size}."
			# e2fsck again
			${BIN}/e2fsck -f -y ${AKHOME}/vendor_dlkm.img

			do_check_super_device_size=true
			unset vendor_dlkm_resized_size
		else
			ui_print "- /vendor_dlkm partition has sufficient space."
		fi

		ui_print "- Trying to mount vendor_dlkm image as read-write..."
		mount ${AKHOME}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || \
			abort "! Failed to mount vendor_dlkm.img as read-write!"

		unset vendor_dlkm_full_space vendor_dlkm_used_space vendor_dlkm_free_space vendor_dlkm_stock_modules_size vendor_dlkm_new_modules_size vendor_dlkm_need_size
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
	else
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
	fi

	ui_print "- Updating /vendor_dlkm image..."
	rm -f ${extract_vendor_dlkm_modules_dir}/*
	cp ${AKHOME}/_vendor_dlkm_modules/* ${extract_vendor_dlkm_modules_dir}/ || \
		abort "! Failed to update modules! No enough free space?"
	sync

	if ${vendor_dlkm_is_ext4}; then
		set_perm 0 0 0644 ${extract_vendor_dlkm_modules_dir}/*
		chcon u:object_r:vendor_file:s0 ${extract_vendor_dlkm_modules_dir}/*
		umount $extract_vendor_dlkm_dir
	else
		for f in "${extract_vendor_dlkm_modules_dir}"/*; do
			echo "vendor_dlkm/lib/modules/$(basename $f) 0 0 0644" >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config
		done
		echo '/vendor_dlkm/lib/modules/.+ u:object_r:vendor_file:s0' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts
		ui_print "- Repacking /vendor_dlkm image..."
		rm -f ${AKHOME}/vendor_dlkm.img
		mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${AKHOME}/vendor_dlkm.img || \
			abort "! Failed to repack the vendor_dlkm image!"
		rm -rf ${extract_vendor_dlkm_dir}

		if [ "$(get_size ${AKHOME}/vendor_dlkm.img)" -gt "$vendor_dlkm_block_size" ]; then
			do_check_super_device_size=true
		else
			# Fill the erofs image file to the same size as the vendor_dlkm partition
			truncate -c -s $vendor_dlkm_block_size ${AKHOME}/vendor_dlkm.img
		fi
	fi

	if ${do_check_super_device_size}; then
		ui_print " "
		ui_print "- The generated image file is larger than the partition size."
		ui_print "- Checking super partition size..."
		check_super_device_size  # If the check here fails, it will be aborted directly.
		ui_print "- Pass!"
	fi

	unset do_check_super_device_size vendor_dlkm_block_size vendor_dlkm_is_ext4 extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir
fi

flash_generic vendor_dlkm
## end vendor_dlkm install

flash_boot; # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk
## end boot install

# Remove files no longer needed to avoid flashing again.
rm ${AKHOME}/Image
rm ${AKHOME}/boot.img
rm ${AKHOME}/boot-new.img
rm ${AKHOME}/vendor_dlkm.img

unset magisk_patched
rm ${AKHOME}/magisk_patched

touch ${AKHOME}/rollback_if_abort_flag

## vendor_boot files attributes
#vendor_boot_attributes() {
#set_perm_recursive 0 0 755 644 $RAMDISK/*;
#set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
#} # end attributes

# vendor_boot shell variables
BLOCK=vendor_boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# reset for vendor_boot patching
reset_ak;

# Try to fix vendor_ramdisk size and vendor_ramdisk table entry information that was corrupted by old versions of magiskboot.
${BIN}/vendor_boot_fix "$BLOCK"
case $? in
	0) ui_print " " "- Successfully repaired the vendor_boot partition!";;
	2) ;;  # The vendor_boot partition is normal and does not need to be repaired.
	*) abort "! Failed to repair vendor_boot partition!";;
esac

# vendor_boot install
dump_boot; # use split_boot to skip ramdisk unpack, e.g. for dtb on devices with hdr v4 but no vendor_kernel_boot

vendor_boot_modules_dir=${RAMDISK}/lib/modules
rm ${vendor_boot_modules_dir}/*
cp ${AKHOME}/_vendor_boot_modules/* ${vendor_boot_modules_dir}/
set_perm 0 0 0644 ${vendor_boot_modules_dir}/*

write_boot  # Since dtbo.img exists in ${home}, the dtbo partition will also be flashed at this time
## end vendor_boot install

# Patch vbmeta
ui_print " "
ui_print "Disable Android Verified Boot..."
for vbmeta_blk in /dev/block/by-name/vbmeta*; do
 ui_print "- Patching $(basename $vbmeta_blk) ..."
 ${BIN}/vbmeta-disable-verification $vbmeta_blk || {
  ui_print "! Failed to patching ${vbmeta_blk}!"
  ui_print "- If the device won't boot after the installation,"
  ui_print "  please manually disable AVB in TWRP."
 }
done
