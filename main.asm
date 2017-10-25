        include "config.inc"
        include "delay.inc"
        include "usart.inc"
        include "usb.inc"

        ;; fuses configuration
        config  FOSC=INTOSCIO   ; internal oscillator block (16MHz)
        config  CFGPLLEN=ON     ; PLL enabled
        config  PLLSEL=PLL3X    ; PLL multiplier = 3
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

        ;; RAM section
.data   udata

tmp     res     1               ; temporary variable
digits  res     5               ; digits for bcd conversion

        ;; eeprom section
.edata  code    0xF00000

        ;; vectors
.reset  code    0x0000
        goto    main            ; reset vector (used goto for loader compatibility)
.isr    code    0x0008
        bra     isr             ; isr vector

.main  code
isr:                            ; isr
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

        call    usart_init
        call    usb_init

main_loop:
        call    usb_service
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

        end
