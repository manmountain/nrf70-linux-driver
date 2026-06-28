#ifndef CONFIG_NRF700X_RADIO_TEST
/*
 * Copyright (c) 2023 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: GPL-2.0
 */

#include <net/cfg80211.h>
#include <linux/etherdevice.h>
#include <net/ieee80211_radiotap.h>
#include <linux/rtnetlink.h>

#include "host_rpu_umac_if.h"
#include "main.h"
#include "fmac_main.h"
#include "fmac_api.h"
#include "fmac_util.h"
#include "queue.h"

#ifdef CONFIG_NRF700X_DATA_TX

#ifdef CONFIG_NRF700X_RAW_DATA_TX
static unsigned char nrf_wifi_map_radiotap_rate(unsigned char rt_rate)
{
	if (rt_rate == 11)
		return 55;

	if (!(rt_rate & 1))
		return rt_rate / 2;

	return 0;
}

static void nrf_wifi_parse_radiotap_tx_meta(struct sk_buff *skb,
					     struct raw_tx_pkt_header *raw_hdr)
{
	struct ieee80211_radiotap_iterator iter;
	unsigned char *arg = NULL;
	int ret = 0;

	if (!skb || !raw_hdr)
		return;

	ret = ieee80211_radiotap_iterator_init(&iter,
					      (struct ieee80211_radiotap_header *)skb->data,
					      skb->len,
					      NULL);
	if (ret)
		return;

	while ((ret = ieee80211_radiotap_iterator_next(&iter)) == 0) {
		arg = iter.this_arg;

		switch (iter.this_arg_index) {
		case IEEE80211_RADIOTAP_RATE:
			if (arg) {
				unsigned char mapped_rate =
					nrf_wifi_map_radiotap_rate(arg[0]);

				if (mapped_rate) {
					raw_hdr->tx_mode =
						NRF_WIFI_FMAC_RAWTX_MODE_LEGACY;
					raw_hdr->data_rate = mapped_rate;
				}
			}
			break;
		case IEEE80211_RADIOTAP_MCS:
			if (arg && (arg[0] & IEEE80211_RADIOTAP_MCS_HAVE_MCS)) {
				raw_hdr->tx_mode = NRF_WIFI_FMAC_RAWTX_MODE_HT;
				raw_hdr->data_rate = min_t(unsigned char, arg[2], 7);
			}
			break;
		case IEEE80211_RADIOTAP_VHT:
			/* VHT field: 2B known, 1B flags, 1B bw, 4B mcs_nss[], ...
			 * mcs_nss[0] is at offset 4 - need at least 5 bytes. */
			if (arg && iter.this_arg_size >= 5) {
				unsigned char mcs_nss = arg[4];

				raw_hdr->tx_mode = NRF_WIFI_FMAC_RAWTX_MODE_VHT;
				raw_hdr->data_rate = min_t(unsigned char,
						   (mcs_nss >> 4) & 0x0f,
						   9);
			}
			break;
		default:
			break;
		}
	}
}

static int nrf_wifi_prepare_monitor_tx_skb(struct sk_buff *skb)
{
	struct raw_tx_pkt_header raw_hdr = {0};
	struct ieee80211_radiotap_header *rtap = NULL;
	u16 rtap_len = 0;
	u32 magic_num = 0;

	if (!skb)
		return -EINVAL;

	if (skb->len >= sizeof(struct raw_tx_pkt_header)) {
		memcpy(&magic_num, skb->data, sizeof(magic_num));
		if (magic_num == NRF_WIFI_MAGIC_NUM_RAWTX)
			return 0;
	}

	if (skb->len >= sizeof(*rtap)) {
		rtap = (struct ieee80211_radiotap_header *)skb->data;

		if (rtap->it_version == 0) {
			rtap_len = le16_to_cpu(rtap->it_len);
			if (rtap_len >= sizeof(*rtap) && rtap_len <= skb->len) {
				nrf_wifi_parse_radiotap_tx_meta(skb, &raw_hdr);
				skb_pull(skb, rtap_len);
			}
		}
	}

	if (skb->len > U16_MAX)
		return -EINVAL;

	if (skb_cow_head(skb, sizeof(struct raw_tx_pkt_header)))
		return -ENOMEM;

	raw_hdr.magic_num = NRF_WIFI_MAGIC_NUM_RAWTX;
	if (raw_hdr.tx_mode == 0 && raw_hdr.data_rate == 0) {
		raw_hdr.tx_mode = NRF_WIFI_FMAC_RAWTX_MODE_LEGACY;
		raw_hdr.data_rate = 0;
	}
	raw_hdr.packet_length = skb->len;
	raw_hdr.queue = NRF_WIFI_FMAC_AC_BE;
	raw_hdr.raw_tx_flag = 1;

	memcpy(skb_push(skb, sizeof(raw_hdr)), &raw_hdr, sizeof(raw_hdr));

	return 0;
}
#endif /* CONFIG_NRF700X_RAW_DATA_TX */

static void nrf_cfg80211_data_tx_routine(struct work_struct *w)
{
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx =
		container_of(w, struct nrf_wifi_fmac_vif_ctx_lnx, ws_data_tx);
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_dev_ctx *fmac_dev_ctx = NULL;
	struct nrf_wifi_fmac_dev_ctx_def *def_dev_ctx = NULL;
	enum nrf_wifi_status status = NRF_WIFI_STATUS_FAIL;
	void *netbuf = NULL;

	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;
	fmac_dev_ctx = rpu_ctx_lnx->rpu_ctx;
	def_dev_ctx = wifi_dev_priv(fmac_dev_ctx);

	netbuf = nrf_wifi_utils_q_dequeue(fmac_dev_ctx->fpriv->opriv,
					  vif_ctx_lnx->data_txq);
	if (netbuf == NULL) {
		pr_err("%s: fail to get tx data from queue\n", __func__);
		return;
	}

	if (vif_ctx_lnx->wdev &&
	    vif_ctx_lnx->wdev->iftype == NL80211_IFTYPE_MONITOR) {
		def_dev_ctx->raw_tx_dequeued_pkts += 1;
	}

#ifdef CONFIG_NRF700X_RAW_DATA_TX
	if (vif_ctx_lnx->wdev &&
	    vif_ctx_lnx->wdev->iftype == NL80211_IFTYPE_MONITOR) {
		struct nrf_wifi_fmac_vif_ctx *fmac_vif =
			def_dev_ctx->vif_ctx[vif_ctx_lnx->if_idx];

		/* Firmware mode event may report plain MONITOR and overwrite
		 * injector if_type. Re-assert injection mode right before raw TX. */
		if (fmac_vif) {
			fmac_vif->if_type = NRF_WIFI_MONITOR_TX_INJECTOR;
			fmac_vif->txinjection_mode = true;
			def_dev_ctx->tx_config.peers[MAX_PEERS].peer_id = MAX_PEERS;
			def_dev_ctx->tx_config.peers[MAX_PEERS].if_idx =
				vif_ctx_lnx->if_idx;
		}

		status = nrf_wifi_prepare_monitor_tx_skb(netbuf);
		if (status) {
			pr_err_ratelimited("%s: monitor tx frame preparation failed (%d)\n",
					   __func__,
					   status);
			def_dev_ctx->raw_tx_prep_fail_pkts += 1;
			nrf_wifi_osal_nbuf_free(fmac_dev_ctx->fpriv->opriv, netbuf);
			goto resched;
		}

		status = nrf_wifi_fmac_start_rawpkt_xmit(rpu_ctx_lnx->rpu_ctx,
							vif_ctx_lnx->if_idx,
							netbuf);
		if (status != NRF_WIFI_STATUS_SUCCESS) {
			pr_err_ratelimited(
				"%s: rawpkt_xmit failed status=%d if_idx=%d if_type=%d txinj=%d\n",
				__func__,
				status,
				vif_ctx_lnx->if_idx,
				fmac_vif ? fmac_vif->if_type : -1,
				fmac_vif ? fmac_vif->txinjection_mode : -1);
			def_dev_ctx->raw_tx_sent_fail_pkts += 1;
			nrf_wifi_osal_nbuf_free(fmac_dev_ctx->fpriv->opriv, netbuf);
		} else {
			def_dev_ctx->raw_tx_sent_ok_pkts += 1;
		}

		goto resched;
	}
#endif

	status = nrf_wifi_fmac_start_xmit(rpu_ctx_lnx->rpu_ctx,
					  vif_ctx_lnx->if_idx, netbuf);
	if (status != NRF_WIFI_STATUS_SUCCESS) {
		pr_err("%s: nrf_wifi_fmac_start_xmit failed\n", __func__);
	}


resched:
	if (nrf_wifi_utils_q_len(fmac_dev_ctx->fpriv->opriv,
				 vif_ctx_lnx->data_txq) > 0) {
		schedule_work(&vif_ctx_lnx->ws_data_tx);
	}
}

static void nrf_cfg80211_queue_monitor_routine(struct work_struct *w)
{
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = container_of(
		w, struct nrf_wifi_fmac_vif_ctx_lnx, ws_queue_monitor);
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_dev_ctx *fmac_dev_ctx = NULL;
	struct nrf_wifi_fmac_dev_ctx_def *def_dev_ctx = NULL;
	struct rpu_host_stats *host_stats = NULL;

	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;
	fmac_dev_ctx = rpu_ctx_lnx->rpu_ctx;
	def_dev_ctx = wifi_dev_priv(fmac_dev_ctx);
	host_stats = &def_dev_ctx->host_stats;

	if (vif_ctx_lnx->num_tx_pkt - host_stats->total_tx_pkts <=
	    CONFIG_NRF700X_MAX_TX_PENDING_QLEN / 2) {
		if (netif_queue_stopped(vif_ctx_lnx->netdev)) {
			netif_wake_queue(vif_ctx_lnx->netdev);
		}
	} else {
		schedule_work(&vif_ctx_lnx->ws_queue_monitor);
	}
}

netdev_tx_t nrf_wifi_netdev_start_xmit(struct sk_buff *skb,
				       struct net_device *netdev)
{
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct nrf_wifi_fmac_dev_ctx *fmac_dev_ctx = NULL;
	struct nrf_wifi_fmac_dev_ctx_def *def_dev_ctx = NULL;
	struct rpu_host_stats *host_stats = NULL;
	int status = -1;
	int ret = NETDEV_TX_OK;

	vif_ctx_lnx = netdev_priv(netdev);
	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;

	fmac_dev_ctx = rpu_ctx_lnx->rpu_ctx;

	def_dev_ctx = wifi_dev_priv(fmac_dev_ctx);
	host_stats = &def_dev_ctx->host_stats;

	if (skb->dev != netdev) {
		pr_err("%s: wrong net dev\n", __func__);
		goto out;
	}

	if ((vif_ctx_lnx->num_tx_pkt - host_stats->total_tx_pkts) >=
	    CONFIG_NRF700X_MAX_TX_PENDING_QLEN) {
		if (!netif_queue_stopped(netdev)) {
			netif_stop_queue(netdev);
		}
		schedule_work(&vif_ctx_lnx->ws_queue_monitor);
	}

	status = nrf_wifi_utils_q_enqueue(fmac_dev_ctx->fpriv->opriv,
					  vif_ctx_lnx->data_txq, skb);

	if (status != NRF_WIFI_STATUS_SUCCESS) {
		pr_err("%s: nrf_wifi_utils_q_enqueue failed\n", __func__);
		ret = NETDEV_TX_BUSY;
		return ret;
	}

	vif_ctx_lnx->num_tx_pkt++;
	schedule_work(&vif_ctx_lnx->ws_data_tx);

out:
	return ret;
}
#endif

int nrf_wifi_netdev_open(struct net_device *netdev)
{
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct nrf_wifi_umac_chg_vif_state_info *vif_info = NULL;
	int status = -1;

	vif_ctx_lnx = netdev_priv(netdev);
	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;

	/* Monitor interfaces have no association and the firmware does not
	 * drive carrier state for them.  Just bring carrier up directly so
	 * raw socket sendto() does not return ENETDOWN. */
	if (vif_ctx_lnx->wdev &&
	    vif_ctx_lnx->wdev->iftype == NL80211_IFTYPE_MONITOR) {
		netif_carrier_on(netdev);
		return 0;
	}

	vif_info = kzalloc(sizeof(*vif_info), GFP_KERNEL);

	if (!vif_info) {
		pr_err("%s: Unable to allocate memory\n", __func__);
		goto out;
	}

	vif_info->state = 1;

	vif_info->if_index = vif_ctx_lnx->if_idx;

	status = nrf_wifi_fmac_chg_vif_state(rpu_ctx_lnx->rpu_ctx,
					     vif_ctx_lnx->if_idx, vif_info);

	if (status == NRF_WIFI_STATUS_FAIL) {
		pr_err("%s: nrf_wifi_fmac_chg_vif_state failed\n", __func__);
		goto out;
	}

out:
	if (vif_info)
		kfree(vif_info);

	return status;
}

int nrf_wifi_netdev_close(struct net_device *netdev)
{
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct nrf_wifi_umac_chg_vif_state_info *vif_info = NULL;
	int status = -1;

	vif_ctx_lnx = netdev_priv(netdev);
	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;

	/* Mirror the open shortcut: monitor interfaces bypass firmware state. */
	if (vif_ctx_lnx->wdev &&
	    vif_ctx_lnx->wdev->iftype == NL80211_IFTYPE_MONITOR) {
		netif_carrier_off(netdev);
		return 0;
	}

	vif_info = kzalloc(sizeof(*vif_info), GFP_KERNEL);

	if (!vif_info) {
		pr_err("%s: Unable to allocate memory\n", __func__);
		goto out;
	}

	vif_info->state = 0;

	vif_info->if_index = vif_ctx_lnx->if_idx;

	status = nrf_wifi_fmac_chg_vif_state(rpu_ctx_lnx->rpu_ctx,
					     vif_ctx_lnx->if_idx, vif_info);

	if (status == NRF_WIFI_STATUS_FAIL) {
		pr_err("%s: nrf_wifi_fmac_chg_vif_state failed\n", __func__);
		goto out;
	}
	flush_work(&vif_ctx_lnx->ws_data_tx);
	flush_work(&vif_ctx_lnx->ws_queue_monitor);

	netif_carrier_off(netdev);
out:
	if (vif_info)
		kfree(vif_info);

	return status;
}

void nrf_wifi_netdev_set_multicast_list(struct net_device *netdev)
{
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct nrf_wifi_umac_mcast_cfg *mcast_info = NULL;
	int status = -1;
	struct netdev_hw_addr *ha = NULL;
	int indx = 0, count = 0;

	vif_ctx_lnx = netdev_priv(netdev);
	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;

	count = netdev_mc_count(netdev);
	mcast_info =
		kzalloc((sizeof(*mcast_info) + (count * NRF_WIFI_ETH_ADDR_LEN)),
			GFP_KERNEL);

	if (!mcast_info) {
		pr_err("%s: Unable to allocate memory\n", __func__);
		goto out;
	}

	netdev_for_each_mc_addr(ha, netdev) {
		memcpy(((char *)(mcast_info->mac_addr) +
			(indx * NRF_WIFI_ETH_ADDR_LEN)),
		       ha->addr, NRF_WIFI_ETH_ADDR_LEN);
		indx++;
	}
	status = nrf_wifi_fmac_set_mcast_addr(rpu_ctx_lnx->rpu_ctx,
					      vif_ctx_lnx->if_idx, mcast_info);

	if (status == NRF_WIFI_STATUS_FAIL) {
		pr_err("%s: nrf_wifi_fmac_chg_vif_state failed\n", __func__);
		goto out;
	}

out:
	if (mcast_info)
		kfree(mcast_info);
}

void nrf_wifi_netdev_frame_rx_callbk_fn(void *os_vif_ctx, void *frm)
{
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct sk_buff *skb = frm;
	struct net_device *netdev = NULL;

	vif_ctx_lnx = os_vif_ctx;
	netdev = vif_ctx_lnx->netdev;

	skb->dev = netdev;
	skb->protocol = eth_type_trans(skb, skb->dev);
	/*
	 * RX frames arrive over SPI and are not accompanied by Linux-recognized
	 * checksum offload metadata. Let the stack validate checksums in software
	 * instead of marking them verified and risking silent payload corruption.
	 */
	skb->ip_summed = CHECKSUM_NONE;

	netif_rx(skb);
}

enum nrf_wifi_status nrf_wifi_netdev_if_state_chg_callbk_fn(
	void *vif_ctx, enum nrf_wifi_fmac_if_carr_state if_state)
{
	enum nrf_wifi_status status = NRF_WIFI_STATUS_FAIL;
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct net_device *netdev = NULL;

	if (!vif_ctx) {
		pr_err("%s: Invalid parameters\n", __func__);
		goto out;
	}

	vif_ctx_lnx = (struct nrf_wifi_fmac_vif_ctx_lnx *)vif_ctx;
	netdev = vif_ctx_lnx->netdev;

	if (if_state == NRF_WIFI_FMAC_IF_CARR_STATE_ON)
		netif_carrier_on(netdev);
	else if (if_state == NRF_WIFI_FMAC_IF_CARR_STATE_OFF)
		netif_carrier_off(netdev);
	else {
		pr_err("%s: Invalid interface state %d\n", __func__, if_state);
		goto out;
	}

	status = NRF_WIFI_STATUS_SUCCESS;
out:
	return status;
}

const struct net_device_ops nrf_wifi_netdev_ops = {
	.ndo_open = nrf_wifi_netdev_open,
	.ndo_stop = nrf_wifi_netdev_close,
#ifdef CONFIG_NRF700X_DATA_TX
	.ndo_start_xmit = nrf_wifi_netdev_start_xmit,
#endif /* CONFIG_NRF700X_DATA_TX */
};

struct nrf_wifi_fmac_vif_ctx_lnx *
nrf_wifi_netdev_add_vif(struct nrf_wifi_ctx_lnx *rpu_ctx_lnx,
			const char *if_name, struct wireless_dev *wdev,
			char *mac_addr)
{
	struct net_device *netdev = NULL;
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct nrf_wifi_fmac_dev_ctx *fmac_dev_ctx = NULL;
	int ret = 0;

	ASSERT_RTNL();

	netdev = alloc_etherdev(sizeof(struct nrf_wifi_fmac_vif_ctx_lnx));

	if (!netdev) {
		pr_err("%s: Unable to allocate memory for a new netdev\n",
		       __func__);
		goto out;
	}

	vif_ctx_lnx = netdev_priv(netdev);
	vif_ctx_lnx->rpu_ctx = rpu_ctx_lnx;
	vif_ctx_lnx->netdev = netdev;
	fmac_dev_ctx = rpu_ctx_lnx->rpu_ctx;

	netdev->netdev_ops = &nrf_wifi_netdev_ops;

	strncpy(netdev->name, if_name, sizeof(netdev->name) - 1);

	eth_hw_addr_set(netdev, mac_addr);

	netdev->ieee80211_ptr = wdev;

	netdev->needed_headroom = TX_BUF_HEADROOM;

	netdev->priv_destructor = free_netdev;
#ifdef CONFIG_NRF700X_DATA_TX
	vif_ctx_lnx->data_txq =
		nrf_wifi_utils_q_alloc(fmac_dev_ctx->fpriv->opriv);
	if (vif_ctx_lnx->data_txq == NULL) {
		goto err_reg_netdev;
	}
	INIT_WORK(&vif_ctx_lnx->ws_data_tx, nrf_cfg80211_data_tx_routine);
	INIT_WORK(&vif_ctx_lnx->ws_queue_monitor,
		  nrf_cfg80211_queue_monitor_routine);
#endif
	ret = register_netdevice(netdev);

	if (ret) {
		pr_err("%s: Unable to register netdev, ret=%d\n", __func__,
		       ret);
		goto err_reg_netdev;
	}

err_reg_netdev:
	if (ret) {
		free_netdev(netdev);
		netdev = NULL;
		vif_ctx_lnx = NULL;
	}
out:
	return vif_ctx_lnx;
}

void nrf_wifi_netdev_del_vif(struct net_device *netdev)
{
	struct nrf_wifi_fmac_vif_ctx_lnx *vif_ctx_lnx = NULL;
	struct nrf_wifi_ctx_lnx *rpu_ctx_lnx = NULL;
	struct nrf_wifi_fmac_dev_ctx *fmac_dev_ctx = NULL;

	vif_ctx_lnx = netdev_priv(netdev);
	rpu_ctx_lnx = vif_ctx_lnx->rpu_ctx;
	fmac_dev_ctx = rpu_ctx_lnx->rpu_ctx;

	nrf_wifi_utils_q_free(fmac_dev_ctx->fpriv->opriv,
			      vif_ctx_lnx->data_txq);

	unregister_netdevice(netdev);
	netdev->ieee80211_ptr = NULL;
}
#endif /* !CONFIG_NRF700X_RADIO_TEST */
