/*
 * Copyright (c) 2015 MediaTek Inc.
 * Author: Biao Huang <biao.huang@mediatek.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <dt-bindings/pinctrl/mt65xx.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/platform_device.h>
#include <linux/pinctrl/pinctrl.h>
#include <linux/regmap.h>

#include "pinctrl-mtk-common.h"
#include "pinctrl-mtk-mt6580.h"

static const struct mtk_pinctrl_devdata mt6580_pinctrl_data = {
	.pins = mtk_pins_mt6580,
	.npins = ARRAY_SIZE(mtk_pins_mt6580),
	.grp_desc = NULL,
	.n_grp_cls = 0,
	.pin_drv_grp = NULL,
	.n_pin_drv_grps = 0,
/*	.spec_pull_set = mt6580_spec_pull_set,
	.spec_ies_smt_set = mt6580_ies_smt_set,
	.spec_pinmux_set = mt6580_spec_pinmux_set,
	.spec_dir_set = mt6580_spec_dir_set, */
	.ies_offset = MTK_PINCTRL_NOT_SUPPORT,
	.smt_offset = MTK_PINCTRL_NOT_SUPPORT,
	.dir_offset = 0x0000,
	.pullen_offset = 0x0100,
	.pullsel_offset = 0x0200,
	.dout_offset = 0x0100,
	.din_offset = 0x0200,
	.pinmux_offset = 0x0300,
	.type1_start = 204,
	.type1_end = 204,
	.port_shf = 4,
	.port_mask = 0xf,
	.port_align = 4,
	.eint_hw = {
		.port_mask = 7,
		.ports     = 6,
		.ap_num    = 224,
		.db_cnt    = 16,
	}, 
};

static int mt6580_pinctrl_probe(struct platform_device *pdev)
{
	pr_err("mt6580 pinctrl probe\n");
	return mtk_pctrl_init(pdev, &mt6580_pinctrl_data, NULL);
}

static const struct of_device_id mt6580_pctrl_match[] = {
	{ .compatible = "mediatek,mt6580-pinctrl", },
	{}
};
MODULE_DEVICE_TABLE(of, mt6580_pctrl_match);

static struct platform_driver mtk_pinctrl_driver = {
	.probe = mt6580_pinctrl_probe,
	.driver = {
		.name = "mediatek-mt6580-pinctrl",
		.of_match_table = mt6580_pctrl_match,
		.pm = &mtk_eint_pm_ops,
	},
};

static int __init mtk_pinctrl_init(void)
{
	return platform_driver_register(&mtk_pinctrl_driver);
}
arch_initcall(mtk_pinctrl_init);
