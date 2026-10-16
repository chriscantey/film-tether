#ifndef FILMTETHER_USB_RESET_H
#define FILMTETHER_USB_RESET_H

#include <stdint.h>

/**
 * Find a USB device by vendor ID and request a hardware re-enumeration via
 * IOKit, equivalent to unplugging and replugging it. The camera drops off the
 * bus, its PTP daemon resets, and it comes back.
 *
 * Returns:
 *   0  = re-enumeration requested (the device disappears briefly), or it
 *        failed and the ResetDevice fallback succeeded
 *  -1  = no matching device found
 *  -2  = IOKit failed to get plug-in interface
 *  -3  = IOKit failed to query USB device interface
 *  -4  = USBDeviceOpen and USBDeviceOpenSeize both failed (another client
 *        holds the device)
 *  -5  = USBDeviceReEnumerate and the ResetDevice fallback both failed
 *
 * The kernel needs time to tear down and re-enumerate the device. The callers
 * wait 6 seconds before re-opening, to give the body's PTP daemon time as well.
 *
 * Vendor ID for Canon: 0x04A9.
 */
int filmtether_reset_usb_device(uint16_t vendor_id);

#endif
