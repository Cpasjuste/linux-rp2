#!/bin/bash

source /opt/retroroot/rr-env armv7h

make -j16 ARCH="arm" CROSS_COMPILE=${RETROROOT_CROSS_PREFIX}

exit 0

mkbootimg \
  --kernel "arch/arm/boot/zImage-dtb" \
  --ramdisk "rp2-initramfs-linux.img" \
  --base "0x80000000" \
  --second_offset "0x00f00000" \
  --cmdline "root=LABEL=RR-BOOT bootopt=64S3,32S1,32S1" \
  --kernel_offset "0x00008000" \
  --ramdisk_offset "0x04000000" \
  --tags_offset "0x0e000000" \
  --pagesize "2048" \
  -o rr-boot.img

mtk_flash -d rp2-da.bin -R -a 0x1d20000 -l 0xDD3000 -F rr-boot.img

