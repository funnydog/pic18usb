LINKSCRIPT = /usr/share/gputils/lkr/18f25k50_g.lkr
OBJECTS = delay.o main.o usart.o usb.o
OUTPUT = usb.hex

all: $(OUTPUT)

$(OUTPUT): $(OBJECTS)
	gplink -m -c -s $(LINKSCRIPT) -o $@ $^

%.o: %.asm
	gpasm -w2 -c -S1 -o $@ $<

# explicit dependencies
delay.o: config.inc
main.o: config.inc delay.inc usart.inc
usart.o: config.inc usart.inc

.PHONY = clean erase flash

clean:
	rm -f *.o *.hex *.cod *.map *.lst *.cof *~

erase:
	pk2cmd -R -P -E

flash: $(OUTPUT)
	pk2cmd -R -P -M -Y -F $<
