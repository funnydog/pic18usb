#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include <hidapi.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	if (hid_init() < 0) {
		fprintf(stderr, "Cannot initialize hidapi\n");
		return EXIT_FAILURE;
	}

	hid_device *handle = hid_open(0x04d8, 0x0001, NULL);
	if (!handle) {
		fprintf(stderr, "Cannot open the hid device 0x04d8:0x0001\n");
		hid_exit();
		return EXIT_FAILURE;
	}

	wchar_t wstr[256];
	if (hid_get_manufacturer_string(handle, wstr, 256) == 0)
		printf("Manufacturer String: %ls\n", wstr);

	if (hid_get_product_string(handle, wstr, 256) == 0)
		printf("Product String: %ls\n", wstr);

	if (hid_get_serial_number_string(handle, wstr, 256) == 0)
		printf("Serial Number String: (%d) %ls\n", wstr[0], wstr);

	uint8_t buf[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};

	if (hid_write(handle, buf, 9) != 9) {
		fprintf(stderr, "hid_write() failure\n");
	}

	if (hid_read(handle, buf, 8) != 8) {
		fprintf(stderr, "hid_read() failure\n");
	} else {
		for (int i = 0; i < 8; i++) {
			printf("buf[%d]: 0x%02X\n", i, buf[i]);
		}
	}

	hid_close(handle);
	hid_exit();

	return 0;
}
