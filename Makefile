LINKSCRIPT = /usr/share/gputils/lkr/18f25k50_g.lkr
OBJECTS = delay.o main.o usart.o usb.o
OUTPUT = usb.hex

CFLAGS = -std=c99 -Wall -Werror -I/usr/include/libusb-1.0 -I/usr/include/hidapi

all: $(OUTPUT) client hidclient

$(OUTPUT): $(OBJECTS)
	gplink -m -c -s $(LINKSCRIPT) -o $@ $^

%.o: %.asm
	gpasm -w2 -c -S1 -o $@ $<

# explicit dependencies
delay.o: config.inc
main.o: config.inc delay.inc usart.inc usb.inc usbdef.inc
usart.o: config.inc usart.inc
usb.o: config.inc usb.inc usbdef.inc

.PHONY = clean erase flash

clean:
	@rm -f client hidclient
	@rm -f *.o *.hex *.cod *.map *.lst *.cof *~

client: client.o
	$(CC) -o $@ $^ -lusb-1.0

hidclient: hidclient.o
	$(CC) -o $@ $^ -lhidapi-hidraw

erase:
	pk2cmd -R -P -E

flash: $(OUTPUT)
	pk2cmd -R -P -M -Y -F $<
