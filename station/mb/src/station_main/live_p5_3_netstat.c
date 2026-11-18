// The bytes this machine took in and sent out on its networks so far, every interface but its loopback summed
// (station/mb src/station_main/live_p5_3_resources.mbt: what of the network the resources' looks read). macOS and the
// BSDs: getifaddrs' link-level entries (`if_data`'s ifi_ibytes, ifi_obytes); Linux: /proc/net/dev; Windows: GetIfTable2
// (iphlpapi, which the reader links). `out[0]` the bytes in, `out[1]` out; 0 where they were read, -1 where not.
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
// (GetIfTable2 is Vista's and later: what the station runs on)
#if !defined(_WIN32_WINNT) || _WIN32_WINNT < 0x0600
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <winsock2.h>
#include <ws2ipdef.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

int sfp53_net_bytes(double *out) {
  MIB_IF_TABLE2 *table = NULL;
  if (GetIfTable2(&table) != NO_ERROR || table == NULL) return -1;
  double in = 0, sent = 0;
  for (ULONG i = 0; i < table->NumEntries; i++) {
    MIB_IF_ROW2 *row = &table->Table[i];
    if (row->Type == IF_TYPE_SOFTWARE_LOOPBACK || !row->InterfaceAndOperStatusFlags.HardwareInterface) continue;
    in += (double)row->InOctets;
    sent += (double)row->OutOctets;
  }
  FreeMibTable(table);
  out[0] = in;
  out[1] = sent;
  return 0;
}

#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <sys/types.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <net/if.h>

int sfp53_net_bytes(double *out) {
  struct ifaddrs *list = NULL;
  if (getifaddrs(&list) != 0) return -1;
  double in = 0, sent = 0;
  for (struct ifaddrs *a = list; a != NULL; a = a->ifa_next) {
    if (a->ifa_addr == NULL || a->ifa_addr->sa_family != AF_LINK || a->ifa_data == NULL) continue;
    if ((a->ifa_flags & IFF_LOOPBACK) != 0) continue;
    const struct if_data *d = (const struct if_data *)a->ifa_data;
    in += (double)d->ifi_ibytes;
    sent += (double)d->ifi_obytes;
  }
  freeifaddrs(list);
  out[0] = in;
  out[1] = sent;
  return 0;
}

#else
int sfp53_net_bytes(double *out) {
  FILE *f = fopen("/proc/net/dev", "r");
  if (f == NULL) return -1;
  char line[512];
  double in = 0, sent = 0;
  int n = 0;
  while (fgets(line, sizeof line, f) != NULL) {
    // (two lines of heads, then `name: rx_bytes packets errs drop fifo frame compressed multicast tx_bytes …`)
    if (++n <= 2) continue;
    char *colon = strchr(line, ':');
    if (colon == NULL) continue;
    *colon = '\0';
    char *name = line;
    while (*name == ' ') name++;
    if (strcmp(name, "lo") == 0) continue;
    unsigned long long rx = 0, tx = 0, skip = 0;
    if (sscanf(colon + 1, "%llu %llu %llu %llu %llu %llu %llu %llu %llu", &rx, &skip, &skip, &skip, &skip, &skip, &skip, &skip, &tx) == 9) {
      in += (double)rx;
      sent += (double)tx;
    }
  }
  fclose(f);
  out[0] = in;
  out[1] = sent;
  return 0;
}
#endif
