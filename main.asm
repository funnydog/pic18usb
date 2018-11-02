        include "config.inc"
        include "delay.inc"
        include "usart.inc"
        include "usb.inc"
        include "usbdef.inc"

        global usb_tx_event, usb_rx_event, usb_status_event

        ;; fuses configuration
        config  FOSC=INTOSCIO   ; internal oscillator block (16MHz)
        config  CFGPLLEN=ON     ; PLL enabled
        config  PLLSEL=PLL3X    ; PLL multiplier = 3
        config  CPUDIV=NOCLKDIV ; PLL divider = 1
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

        ;; eeprom section
.edata  code    0xF00000

        ;; vectors
.reset  code    0x0000
        goto    main            ; reset vector (used goto for loader compatibility)
.isr    code    0x0008
        goto    isr             ; isr vector

.main  code
isr:                            ; isr
        call    usart_isr
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
        bsf     INTCON, GIE, B
        bsf     INTCON, PEIE, B

        ;; speed up the internal clock to 16MHz
        bsf     OSCCON, IRCF2, B ; default: 1Mhz, IRCF1:0 = 3
        btfss   OSCCON, HFIOFS, B
        bra     $-2             ; wait for the clock to stabilize

        call    usart_init
        call    usb_init

main_loop:
        call    usb_service
        bra     main_loop

usb_status_event:
        return

usb_tx_event:
        lfsr    FSR0, BD1IBC
        call    usart_send_h8
        movlw   'T'
        call    usart_send
        call    usart_send_nl
        return

usb_rx_event:
        btg     LATB, RB5, A
        return

        end
