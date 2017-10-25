        include "config.inc"

        global  usart_init, usart_send, usart_recv, usart_send_str
        global  usart_send_h4, usart_send_h8, usart_send_h16, usart_send_h32
        global  usart_send_s16, usart_send_u16

BAUD    EQU     9600

.usartd udata_acs
tmp     res     1               ; temporary value
digits  res     5               ; digits for BCD conversion

.usartc code

        ;; initialize the usart module
usart_init
        bsf     RCSTA, SPEN, A  ; enable the usart module
        bsf     TRISC, 7, A     ; RX pin
        bsf     TRISC, 6, A     ; TX pin
        bcf     TXSTA, SYNC, A  ; asynchronous mode
        bcf     TXSTA, BRGH, A  ; low speed mode
        bcf     BAUDCON, BRG16, A
        movlw   FOSC/64/BAUD-1  ; 9600 baud
        movwf   SPBRG, A
        bcf     PIE1, RCIE, A   ; disable RX ints
        bcf     PIE1, TXIE, A   ; disable TX ints
        bsf     TXSTA, TXEN, A  ; enable tx
        bsf     RCSTA, CREN, A  ; enable rx
        return

        ;; receive a byte in W
usart_recv
        btfss   PIR1, RCIF, A   ; check for receive complete
        bra     usart_recv
        bcf     STATUS, C, A    ; clear the carry
        movf    RCREG, W, A     ; load the data accumulator
        btfsc   RCSTA, OERR, A  ; check for overflow
        bra     ovflow
        btfsc   RCSTA, FERR, A  ; check for frame error
        bra     framerr
        return
ovflow  movlw   -1              ; overflow
        bra     clear
framerr movlw   -2              ; frame error
clear   bsf     STATUS, C, A
        bcf     RCSTA, CREN, A  ; clear errors
        bsf     RCSTA, CREN, A  ;
        return

        ;; send the byte in W
usart_send
        btfss   TXSTA, TRMT, A  ; wait to complete tx
        bra     usart_send
        movwf   TXREG, A        ; send W
        return

        ;; send a string in TBLPTR
usart_send_str
        tblrd*+
        movf    TABLAT, W, A    ; read the value and increment pointer
        btfsc   STATUS, Z, A    ; if W == 0
        return
        call    usart_send
        bra     usart_send_str  ; next char

        ;; print a 32bit hex value
usart_send_h32:
        movlw   4
        bra     $+4
usart_send_h16:
        movlw   2
        movwf   tmp, A
usart_send_h_loop:
        swapf   INDF0, W, A
        rcall   usart_send_h4
        movf    POSTINC0, W, A
        rcall   usart_send_h4
        decfsz  tmp, F, A
        bra     usart_send_h_loop
        return
        ;; print a 8bit hex value
usart_send_h8:
        swapf   INDF0, W, A     ; most significant nibble
        rcall   usart_send_h4
        movf    INDF0, W, A     ; least significant nibble
        ;; print a 4bit hex value
usart_send_h4:
        andlw   0x0F            ; isolate the lower nibble
        addlw   255 - 9         ; add 256 in two steps but only the
        addlw   9 - 0 + 1       ; last addition affects the final C flag
        btfss   STATUS, C, A
        addlw   'A'-10-'0'      ; letter detected: add 'A'-10-'0'
        addlw   '0'             ; add '0'
        bra     usart_send      ; tail call usart_send

        ;; print a 16bit signed value
usart_send_s16:
        movlw   '+'             ; set the sign of the value
        movf    POSTINC0, F, A  ; *FSR0++
        btfss   POSTDEC0, 7, A  ; *FSR0--
        bra     usart_send_sign
        comf    POSTINC0, F, A  ; *FSR0++
        comf    POSTDEC0, F, A  ; *FSR0--
        incf    POSTINC0, F, A  ; *FSR0++
        btfsc   STATUS, Z, A
        incf    INDF0, F, A     ; *FSR0
        movf    POSTDEC0, F, A  ; *FSR0--
        movlw   '-'
usart_send_sign:
        call    usart_send      ; print the sign of the value

        ;; print a 16bit unsigned value
usart_send_u16:
        call    b16_d5
        lfsr    FSR0, digits
        movlw   5
        movwf   tmp, A
usart_send_u_loop:
        movf    POSTINC0, W, A
        addlw   '0'
        rcall   usart_send
        decfsz  tmp, F, A
        bra     usart_send_u_loop
        return

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
        movwf   digits+1, A     ; B3 = A3 - 16
        addwf   digits+1, F, A  ; B3 = 2*(A3 - 16) = 2A3 - 32
        addlw   226             ; W  = A3 - 16 - 30 = A3 - 46
        movwf   digits+2, A     ; B2 = A3 - 46
        addlw   50              ; W  = A3 - 40 + 50 = A3 + 4
        movwf   digits+4, A     ; B0 = A3 + 4

        movf    POSTDEC0, W, A  ; W  = A3 * 16 + A2
        andlw   0x0F            ; W  = A2
        addwf   digits+2, F, A  ; B2 = A3 + A2 - 46
        addwf   digits+2, F, A  ; B2 = A3 + 2A2 - 46
        addwf   digits+4, F, A  ; B0 = A3 + A2 + 4
        addlw   233             ; W  = A2 - 23
        movwf   digits+3, A     ; B1 = A2 - 23
        addwf   digits+3, F, A  ; B1 = 2*(A2 - 23) = 2A2 - 46
        addwf   digits+3, F, A  ; B1 = 3*(A2 - 23) = 3A2 - 69

        swapf   INDF0, W, A     ; W  = A0 * 16 + A1
        andlw   0x0F            ; W  = A1
        addwf   digits+3, F, A  ; B1 = 3A2 + A1 - 69
        addwf   digits+4, F, A  ; B0 = A3 + A2 + A1 + 4 (C = 0)

        rlcf    digits+3, F, A  ; B1 = 2*(3A2 + A1 - 69) = 6A2 + 2A1 - 138 (C = 1)
        rlcf    digits+4, F, A  ; B0 = 2*(A3+A2+A1+4)+C = 2A3+2A2+2A1+9
        comf    digits+4, F, A  ; B0 = ~(2A3+2A2+2A1+9)= -2A3-2A2-2A1-10
        rlcf    digits+4, F, A  ; B0 = 2*(-2A3-2A2-2A1-10) = -4A3-4A2-4A1-20

        movf    INDF0, W, A     ; W  = A1*16+A0
        andlw   0x0F            ; W  = A0
        addwf   digits+4, F, A  ; B0 = A0-4A3-4A2-4A1-20 (C=0)
        rlcf    digits+1, F, A  ; B3 = 2*(2A3-32) = 4A3 - 64

        movlw   0x07            ; W  = 7
        movwf   digits+0, A     ; B4 = 7

        ;; normalization
        ;; B0 = A0-4(A3+A2+A1)-20 range  -5 .. -200
        ;; B1 = 6A2+2A1-138       range -18 .. -138
        ;; B2 = A3+2A2-46         range  -1 ..  -46
        ;; B3 = 4A3-64            range  -4 ..  -64
        ;; B4 = 7                 7
        movlw   10              ; W  = 10
b16_d5_lb1:                     ; do {
        decf    digits+3, F, A  ;   B1 -= 1
        addwf   digits+4, F, A  ;   B0 += 10
        skpc                    ; } while B0 < 0
        bra     b16_d5_lb1
b16_d5_lb2:                     ; do {
        decf    digits+2, F, A  ;   B2 -= 1
        addwf   digits+3, F, A  ;   B1 += 10
        skpc                    ; } while B1 < 0
        bra     b16_d5_lb2
b16_d5_lb3:                     ; do {
        decf    digits+1, F, A  ;  B3 -= 1
        addwf   digits+2, F, A  ;  B2 += 10
        skpc                    ; } while B2 < 0
        bra     b16_d5_lb3
b16_d5_lb4:                     ; do {
        decf    digits+0, F, A  ;  B4 -= 1
        addwf   digits+1, F, A  ;  B3 += 10
        skpc                    ; } while B3 < 0
        bra     b16_d5_lb4
        retlw   0

        end
