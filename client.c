#include <libusb.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#define DEFAULT_STATE     0
#define ADDRESS_STATE     1
#define CONFIG_STATE      2

#define DEVICE            0x80
#define INTERFACE         0x81
#define ENDPOINT          0x82

#define DIRIN             0x80
#define DIROUT            0x00

#define GET_STATUS        0x00
#define CLEAR_FEATURE     0x01
#define SET_FEATURE       0x03
#define SET_ADDRESS       0x05
#define GET_DESCRIPTOR    0x06
#define SET_DESCRIPTOR    0x07
#define GET_CONFIGURATION 0x08
#define SET_CONFIGURATION 0x09
#define GET_INTERFACE     0x0A
#define SET_INTERFACE     0x0B
#define SYNCH_FRAME       0x0C

struct request
{
        uint8_t bmRequestType;
        uint8_t bRequest;
        uint16_t wValue;
        uint16_t wIndex;
        uint16_t wLength;

        int shouldfail;
} addressed[] = {
        { DIROUT|DEVICE,    GET_STATUS,    0,    0, 2, 0 }, /* 0 */
        { DIROUT|INTERFACE, GET_STATUS,    0,    0, 2, 0 }, /* 1 */
        { DIROUT|ENDPOINT,  GET_STATUS,    0,    0, 2, 0 }, /* 2 */
        { DIROUT|ENDPOINT,  GET_STATUS,    0, 0x80, 2, 0 }, /* 3 */
        { DIROUT|ENDPOINT,  GET_STATUS,    0,    1, 2, 1 }, /* 4 */
        { DIROUT|ENDPOINT,  GET_STATUS,    0, 0x81, 2, 1 }, /* 5 */

        { DIROUT|DEVICE,    SET_FEATURE,   1,    0, 0, 0 }, /* 6 */
        { DIROUT|INTERFACE, SET_FEATURE,   0,    0, 0, 0 }, /* 7 */
        { DIROUT|ENDPOINT,  SET_FEATURE,   1,    0, 0, 0 }, /* 8 */
        { DIROUT|ENDPOINT,  SET_FEATURE,   1, 0x80, 0, 0 }, /* 9 */
        { DIROUT|ENDPOINT,  SET_FEATURE,   1,    1, 0, 1 }, /* 10 */
        { DIROUT|ENDPOINT,  SET_FEATURE,   1, 0x81, 0, 1 }, /* 11 */

        { DIROUT|DEVICE,    CLEAR_FEATURE, 1,    0, 0, 0 }, /* 12 */
        { DIROUT|INTERFACE, CLEAR_FEATURE, 0,    0, 0, 0 }, /* 13 */
        { DIROUT|ENDPOINT,  CLEAR_FEATURE, 1,    0, 0, 0 }, /* 14 */
        { DIROUT|ENDPOINT,  CLEAR_FEATURE, 1, 0x80, 0, 0 }, /* 15 */
        { DIROUT|ENDPOINT,  CLEAR_FEATURE, 1,    1, 0, 1 }, /* 16 */
        { DIROUT|ENDPOINT,  CLEAR_FEATURE, 1, 0x81, 0, 1 }, /* 17 */
};

static int get_status(libusb_device_handle *handle, uint8_t target, uint8_t idx)
{
        uint16_t status;
        int r = libusb_control_transfer(
                handle,
                0x80 | target,  /* bmRequestType */
                0x00,           /* bRequest */
                0,              /* wValue */
                idx,            /* wIndex */
                (uint8_t *)&status, /* data */
                2,              /* wLength */
                100);           /* timeout */
        if (r < 0) {
                fprintf(stderr, "GET_STATUS target: %2x idx: %2x error\n", target, idx);
                return r;
        }
        return status;
}

static int set_portb(libusb_device_handle *handle, uint8_t value)
{
        return libusb_control_transfer(
                handle,
                LIBUSB_RECIPIENT_DEVICE | LIBUSB_REQUEST_TYPE_VENDOR,
                0,              /* bRequest (SET) */
                value,		/* wValue (RB3) */
                0,              /* wIndex   */
                NULL,           /* data     */
                0,              /* wLength  */
                100);
}

int main(int argc, char *argv[])
{
        libusb_context *ctx = NULL;

        if (libusb_init(&ctx) < 0) {
                fprintf(stderr, "Cannot initialize libusb\n");
                return EXIT_FAILURE;
        }
        /* set the verbosity level of libusb */
        libusb_set_debug(ctx, 3);

        libusb_device_handle *handle;
        handle = libusb_open_device_with_vid_pid(ctx, 0x04D8, 0x0001);
        if (!handle) {
                fprintf(stderr, "cannot open the device\n");
                goto fail;
        }

        if (libusb_set_configuration(handle, 1) < 0) {
                fprintf(stderr, "cannot set the configuration\n");
                goto fail_close;
        }

        if (libusb_claim_interface(handle, 0) < 0) {
                fprintf(stderr, "cannot claim the interface\n");
                goto fail_close;
        }

        int status = get_status(handle, 0, 0);
        if (status >= 0) {
                fprintf(stdout, "GET_STATUS (device    ): %04x\n", status);
        }

        status = get_status(handle, 1, 0);
        if (status >= 0) {
                fprintf(stdout, "GET_STATUS (interface0): %04x\n", status);
        }

        status = get_status(handle, 2, 0x80);
        if (status >= 0) {
                fprintf(stdout, "GET_STATUS (ep0 IN    ): %04x\n", status);
        }

        status = get_status(handle, 2, 0x00);
        if (status >= 0) {
                fprintf(stdout, "GET_STATUS (ep0 OUT   ): %04x\n", status);
        }

        /* configured state */
        uint8_t buf[512];
        for (int i = 0; i < sizeof(addressed)/sizeof(addressed[0]); i++) {
                struct request *req = addressed + i;
                int r = libusb_control_transfer(
                        handle,
                        req->bmRequestType,
                        req->bRequest,
                        req->wValue,
                        req->wIndex,
                        buf,
                        req->wLength,
                        100);

                if (req->shouldfail && r == 0) {
                        fprintf(stderr, "Request %d didn't fail\n", i);
                } else if (r < 0) {
                        fprintf(stderr, "Request %d failed %d\n", i, r);
                }
        }

	for (int i = 0; i < 1000; i++) {
		if (set_portb(handle, (i&1) ? 3<<3 : 0) < 0) {
			fprintf(stderr, "cannot send vendor request %i\n", i);
		}
		sleep(1);
	}

        libusb_close(handle);
        libusb_exit(ctx);
        return EXIT_SUCCESS;
fail_close:
        libusb_close(handle);
fail:
        libusb_exit(ctx);
        return EXIT_FAILURE;
}
