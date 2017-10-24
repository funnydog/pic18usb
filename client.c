#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <libusb.h>

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

        int r = libusb_control_transfer(
                handle,
                LIBUSB_RECIPIENT_DEVICE | LIBUSB_REQUEST_TYPE_VENDOR,
                1,              /* bRequest */
                0,              /* wValue   */
                0,              /* wIndex   */
                NULL,           /* data     */
                0,              /* wLength  */
                100);
        if (r < 0) {
                fprintf(stderr, "cannot send the vendor specific request\n");
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

        libusb_close(handle);
        libusb_exit(ctx);
        return EXIT_SUCCESS;
fail_close:
        libusb_close(handle);
fail:
        libusb_exit(ctx);
        return EXIT_FAILURE;
}
