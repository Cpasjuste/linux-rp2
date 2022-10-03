#ifndef __SOC_MEDIATEK_SCPSYS_H
#define __SOC_MEDIATEK_SCPSYS_H

#include <linux/kernel.h>

int scpsys_cpu_power_on(int cpu);
int scpsys_cpu_power_off(int cpu, bool wfi);

#endif
