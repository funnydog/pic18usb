        include "config.inc"
        include "delay.inc"
        include "usart.inc"
        include "usb.inc"

        ;; fuses configuration
        config  FOSC=INTOSCIO   ; internal oscillator block (16MHz)
        config  CFGPLLEN=ON     ; PLL enabled
        config  PLLSEL=PLL3X    ; PLL multiplier = 4
        config  CPUDIV=CLKDIV3  ; PLL divider = 3
        config  LS48MHZ=SYS48x8 ; USB clock set to 6Mhz
        config  PCLKEN=OFF      ; Primary clock can be disabled in software
        config  FCMEN=OFF       ; Fail-Safe Clock Monitor disabled
        config  IESO=OFF        ; Oscillator Switchover mode disabled
        config  PWRTEN=ON       ; Power up timer enabled
        config  BOREN=OFF       ; BOR enabled in hardware, disabled in sleep
        config  BORV=285        ; BOR set to 2.85V nominal
        config  WDTEN=OFF       ; Watchdog Timer disabled in hardware
        config  WDTPS=1         ; Watchdog Timer postscaler = 1
        ;; config  CPP2MX=RB3      ; CCP2 input/output multiplexed with RB3
        config  PBADEN=OFF      ; PortB AD pins configured as digital IO on reset
        config  T3CMX=RB5       ; Timer3 Clock input is multiplexed on RB5
        config  SDOMX=RC7       ; SDO output is multiplexed on RC7
        config  MCLRE=ON        ; MCLR pin enabled, RE3 input disabled
        config  STVREN=ON       ; Stack full/underflow won't cause reset
        config  LVP=OFF         ; Single-Supply ICSP disabled
        config  ICPRT=OFF       ; ICPort disabled
        config  XINST=OFF       ; Instruction set extension disabled
        config  DEBUG=OFF       ; background debugger disabled
        config  CP0=OFF         ; Block 0 is not code-protected
        config  CP1=OFF         ; Block 1 is not code-protected
        config  CP2=OFF         ; Block 2 is not code-protected
        config  CP3=OFF         ; Block 3 is not code-protected
        config  CPB=OFF         ; Boot block is not code-protected
        config  CPD=OFF         ; Data EEPROM is not code-protected
        config  WRT0=OFF        ; Block 0 is not write-protected
        config  WRT1=OFF        ; Block 1 is not write-protected
        config  WRT2=OFF        ; Block 2 is not write-protected
        config  WRT3=OFF        ; Block 3 is not write-protected
        config  WRTB=OFF        ; Boot block is not write-protected
        config  WRTC=OFF        ; Configuration registers are not write-protected
        config  WRTD=OFF        ; Data EEPROM is not write-protected
        config  EBTR0=OFF       ; Block 0 is not protected from table reads in other blocks
        config  EBTR1=OFF       ; Block 1 is not protected from table reads in other blocks
        config  EBTR2=OFF       ; Block 2 is not protected from table reads in other blocks
        config  EBTR3=OFF       ; Block 3 is not protected from table reads in other blocks
        config  EBTRB=OFF       ; Boot block is not protected from table reads in other blocks

        ;; constants
FFAULT  equ     3               ; FOC|FSCG|FSCV
FOC     equ     2               ; thermocouple is open
FSCG    equ     1               ; thermocouple is shorted to GND
FSCV    equ     0               ; thermocouple is shorted to Vcc

.data   udata

        ;; variables
tmp     res     2
sample  res     4               ; 32bit sampled data
tctemp  res     2               ; termocouple temperature
intemp  res     2               ; internal temperature
tcflags res     1               ; flags
digits  res     5               ; digits for bcd conversion

.edata  code    0xF00000

        ;; variables stored in EEPROM

        ;; entry code section
.reset  code    0x0000
        goto    main

.isr    code    0x0008
        bra     isr

        ;; main code
.main  code
isr:
        retfie  FAST

        ;; main code
main:
        ;; initialize the ports as digital outputs with value 0
        movlb   0xF             ; select the bank 0xF
        clrf    ANSELA, B       ; ANSEL A/B/C are not in ACCESS BANK
        clrf    ANSELB, B
        clrf    ANSELC, B
        clrf    LATA, B         ; clear the PORTA latches
        clrf    TRISA, B        ; set RA0..RA7 as outputs
        clrf    LATB, B         ; clear the PORTB latches
        clrf    TRISB, B        ; set RB0..RB7 as outputs
        clrf    LATC, B         ; clear the PORTC latches
        clrf    TRISC, B        ; set RC0..RC7 as outputs

        ;; enable the interrupts
        bcf     PIR2, CCP2IF, B
        bcf     PIE2, CCP2IE, B
        bcf     INTCON, GIE, B
        bcf     INTCON, PEIE, B

        ;; speed up the internal clock to 16MHz
        bsf     OSCCON, IRCF2, B ; increase the freq to 16MHz
        delaycy 65536           ; a small delay for things to settle

        ;; TODO - set MSSP master mode
        bcf     SSP1CON1, SSPEN, B ; disable the MSSP
        movlw   0               ; 1<<SMP|1<<CKE
        movwf   SSP1STAT, B     ; sample at the end, falling signal
        movlw   0x02
        movwf   SSP1CON1, B     ; enable SPI master mode
        bcf     PIE1, SSPIE, B  ; disable the SPI interrupt
        bcf     PIE2, BCLIE, B  ; disable the BUS collision interrupt
        bsf     TRISB, 0, B     ; set RB0 as input
        bsf     LATB, 2, B      ; set SS to inactive
        bsf     SSP1CON1, SSPEN, B ; enable the MSSP
        movlb   0x0             ; select the bank0

        call    usart_init
        call    usb_init

main_loop:
        call    usb_service
        ;; movlw   '\r'
        ;; call    usart_send
        ;; movlw   '\n'
        ;; call    usart_send
        bra     main_loop

        ;; read the 32bit value from the MAX31855K
        lfsr    FSR0, sample
        movlw   4
        movwf   tmp, B
        bcf     LATB, 2, A      ; select the chip
sample_loop:
        bcf     PIR1, SSPIF, A
        clrf    SSP1BUF, A      ; clear SSP1BUF to start receiving
        btfss   PIR1, SSPIF, A
        bra     $-2             ; wait until the data is received
        movf    SSP1BUF, W, A
        movwf   POSTINC0, A
        decfsz  tmp, F, B
        bra     sample_loop
        bsf     LATB, 2, A      ; unselect the chip

        ;; move the tc temperature (14bits) to tctemp[0:1]
        ;; and shift right 2 bits while preserving
        ;; the sign of the value

        movf    sample+0, W, B
        movwf   tctemp+1, B     ; move sample+0 to tctemp+1
        movf    sample+1, W, B
        movwf   tctemp+0, B     ; move sample+1 to tctemp+0

        rlcf    tctemp+1, W, B  ; move the sign bit in the carry flag
        rrcf    tctemp+1, F, B  ; shift right by 1 bit
        rrcf    tctemp+0, F, B  ; shift right by 1 bit
        rlcf    tctemp+1, W, B  ; move the sign bit in the carry flag
        rrcf    tctemp+1, F, B  ; shift right by 1 bit
        rrcf    tctemp+0, F, B  ; shift right by 1 bit

        ;; move the internal temperature (12bits) to intemp[0:1]
        ;; and sign extend the stored value to 16bits
        swapf   sample+2, W, B
        andlw   0x0F
        movwf   intemp+1, B     ; the most significant nibble in intemp+1
        movlw   0xF0
        btfsc   intemp+1, 4, B  ; check the sign bit
        iorwf   intemp+1, F, B  ; sign-extend the 12bit value

        swapf   sample+2, W, B
        andlw   0xF0
        movwf   intemp+0, B     ; the middle nibble in intemp+0

        swapf   sample+3, W, B
        andlw   0x0F
        iorwf   intemp+0, F, B  ; the least significant nibble in intemp+0

        ;; set the thermocouple flags
        clrf    tcflags, B      ; clear everything
        btfsc   sample+1, 0, B  ; set the Fault bit (OC|SCV|SCV)
        bsf     tcflags, FFAULT, B
        btfsc   sample+3, 0, B  ; set the OC bit (tc open)
        bsf     tcflags, FOC, B
        btfsc   sample+3, 1, B  ; set the SCG bit (tc connected to GND)
        bsf     tcflags, FSCG, B
        btfsc   sample+3, 2, B  ; set the SCV bit (tc connected to Vcc)
        bsf     tcflags, FSCV, B

        lfsr    FSR0, tctemp
        call    print_s16

        movlw   ' '
        call    usart_send
        lfsr    FSR0, tcflags
        call    print_h8

        movlw   ' '
        call    usart_send

        lfsr    FSR0, sample
        call    print_h32

        movlw   '\r'
        call    usart_send
        movlw   '\n'
        call    usart_send

        ;; delay loop
        movlw   200
        movwf   tmp, B
delay_loop:
        delaycy 12500
        decfsz  tmp, F, B
        bra     delay_loop

        bra     main_loop

        ;; print a 32bit hex value
print_h32:
        movlw   4
        movwf   tmp, B
print_h32_loop:
        swapf   INDF0, W, A
        call    print_h4
        movf    POSTINC0, W, A
        call    print_h4
        decfsz  tmp, F, B
        bra     print_h32_loop
        retlw   0

        ;; print a 8bit hex value
print_h8:
        swapf   INDF0, W, A     ; most significant nibble
        call    print_h4
        movf    INDF0, W, A     ; least significant nibble

        ;; print a 4bit hex value
print_h4:
        andlw   0x0F            ; isolate the lower nibble
        addlw   255 - 9         ; add 256 in two steps but only the
        addlw   9 - 0 + 1       ; last addition affects the final C flag
        btfss   STATUS, C, A
        addlw   'A'-10-'0'      ; letter detected: add 'A'-10-'0'
        addlw   '0'             ; add '0'
        bra     usart_send      ; tail call usart_send

        ;; print a 16bit signed value
print_s16:
        movlw   '+'             ; set the sign of the value
        movf    POSTINC0, F, A  ; *FSR0++
        btfss   POSTDEC0, 7, A  ; *FSR0--
        bra     print_sign
        comf    POSTINC0, F, A  ; *FSR0++
        comf    POSTDEC0, F, A  ; *FSR0--
        incf    POSTINC0, F, A  ; *FSR0++
        btfsc   STATUS, Z, A
        incf    INDF0, F, A     ; *FSR0
        movf    POSTDEC0, F, A  ; *FSR0--
        movlw   '-'
print_sign:
        call    usart_send      ; print the sign of the value

        ;; print a 16bit unsigned value
print_u16:
        call    b16_d5
        lfsr    FSR0, digits
        movlw   5
        movwf   tmp, B
print_loop:
        movf    POSTINC0, W, A
        addlw   '0'
        call    usart_send
        decfsz  tmp, F, B
        bra     print_loop
        retlw   0

        ;; b16_d5 - convert a 16bit value to BCD
        ;; @FSR0: address of the 16bit value [LSB, MSB]
        ;;
        ;; Convert a 16bit value pointed by FSR0 into
        ;; 5 digits BCD values saved in digits[5]
        ;;
        ;; Return: no value
b16_d5:
        movf    POSTINC0, W, A  ; we have to start from MSB
        swapf   INDF0, W, A     ; W  = A2*16 + A3
        iorlw   0xF0            ; W  = A3 - 16
        movwf   digits+1, B     ; B3 = A3 - 16
        addwf   digits+1, F, B  ; B3 = 2*(A3 - 16) = 2A3 - 32
        addlw   226             ; W  = A3 - 16 - 30 = A3 - 46
        movwf   digits+2, B     ; B2 = A3 - 46
        addlw   50              ; W  = A3 - 40 + 50 = A3 + 4
        movwf   digits+4, B     ; B0 = A3 + 4

        movf    POSTDEC0, W, A  ; W  = A3 * 16 + A2
        andlw   0x0F            ; W  = A2
        addwf   digits+2, F, B  ; B2 = A3 + A2 - 46
        addwf   digits+2, F, B  ; B2 = A3 + 2A2 - 46
        addwf   digits+4, F, B  ; B0 = A3 + A2 + 4
        addlw   233             ; W  = A2 - 23
        movwf   digits+3, B     ; B1 = A2 - 23
        addwf   digits+3, F, B  ; B1 = 2*(A2 - 23) = 2A2 - 46
        addwf   digits+3, F, B  ; B1 = 3*(A2 - 23) = 3A2 - 69

        swapf   INDF0, W, A     ; W  = A0 * 16 + A1
        andlw   0x0F            ; W  = A1
        addwf   digits+3, F, B  ; B1 = 3A2 + A1 - 69
        addwf   digits+4, F, B  ; B0 = A3 + A2 + A1 + 4 (C = 0)

        rlcf    digits+3, F, B  ; B1 = 2*(3A2 + A1 - 69) = 6A2 + 2A1 - 138 (C = 1)
        rlcf    digits+4, F, B  ; B0 = 2*(A3+A2+A1+4)+C = 2A3+2A2+2A1+9
        comf    digits+4, F, B  ; B0 = ~(2A3+2A2+2A1+9)= -2A3-2A2-2A1-10
        rlcf    digits+4, F, B  ; B0 = 2*(-2A3-2A2-2A1-10) = -4A3-4A2-4A1-20

        movf    INDF0, W, A     ; W  = A1*16+A0
        andlw   0x0F            ; W  = A0
        addwf   digits+4, F, B  ; B0 = A0-4A3-4A2-4A1-20 (C=0)
        rlcf    digits+1, F, B  ; B3 = 2*(2A3-32) = 4A3 - 64

        movlw   0x07            ; W  = 7
        movwf   digits+0, B     ; B4 = 7

        ;; normalization
        ;; B0 = A0-4(A3+A2+A1)-20 range  -5 .. -200
        ;; B1 = 6A2+2A1-138       range -18 .. -138
        ;; B2 = A3+2A2-46         range  -1 ..  -46
        ;; B3 = 4A3-64            range  -4 ..  -64
        ;; B4 = 7                 7
        movlw   10              ; W  = 10
b16_d5_lb1:                     ; do {
        decf    digits+3, F, B  ;   B1 -= 1
        addwf   digits+4, F, B  ;   B0 += 10
        skpc                    ; } while B0 < 0
        bra     b16_d5_lb1
b16_d5_lb2:                     ; do {
        decf    digits+2, F, B  ;   B2 -= 1
        addwf   digits+3, F, B  ;   B1 += 10
        skpc                    ; } while B1 < 0
        bra     b16_d5_lb2
b16_d5_lb3:                     ; do {
        decf    digits+1, F, B  ;  B3 -= 1
        addwf   digits+2, F, B  ;  B2 += 10
        skpc                    ; } while B2 < 0
        bra     b16_d5_lb3
b16_d5_lb4:                     ; do {
        decf    digits+0, F, B  ;  B4 -= 1
        addwf   digits+1, F, B  ;  B3 += 10
        skpc                    ; } while B3 < 0
        bra     b16_d5_lb4
        retlw   0

        ;; LCD PCD8544
        ;; P | DESCRIPTION
        ;; --+------------
        ;; 1 | RESET
        ;; 2 | SCE\
        ;; 3 | DC
        ;; 4 | SDIN
        ;; 5 | SCLK

        end
