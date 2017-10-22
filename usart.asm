	include "config.inc"

	global usart_init, usart_send, usart_recv, usart_send_str

BAUD	EQU	9600

.usart	code

	;; initialize the usart module
usart_init
	bsf	RCSTA, SPEN, A	; enable the usart module
	bsf	TRISC, 7, A	; RX pin
	bsf	TRISC, 6, A	; TX pin
	bcf	TXSTA, SYNC, A	; asynchronous mode
	bcf	TXSTA, BRGH, A	; low speed mode
	bcf	BAUDCON, BRG16, A
	movlw	FOSC/64/BAUD-1	; 9600 baud
	movwf	SPBRG, A
	bcf	PIE1, RCIE, A	; disable RX ints
	bcf	PIE1, TXIE, A	; disable TX ints
	bsf	TXSTA, TXEN, A	; enable tx
	bsf	RCSTA, CREN, A	; enable rx
	return

	;; receive a byte in W
usart_recv
	btfss	PIR1, RCIF, A	; check for receive complete
	bra	usart_recv
	bcf	STATUS, C, A	; clear the carry
	movf	RCREG, W, A	; load the data accumulator
	btfsc	RCSTA, OERR, A	; check for overflow
	bra	ovflow
	btfsc	RCSTA, FERR, A	; check for frame error
	bra	framerr
	return
ovflow	movlw	-1		; overflow
	bra	clear
framerr	movlw	-2		; frame error
clear	bsf	STATUS, C, A
	bcf	RCSTA, CREN, A	; clear errors
	bsf	RCSTA, CREN, A	;
	return

	;; send the byte in W
usart_send
	btfss	TXSTA, TRMT, A	; wait to complete tx
	bra	usart_send
	movwf	TXREG, A	; send W
	return

	;; send a string in TBLPTR
usart_send_str
	tblrd*+
	movf	TABLAT, W, A	; read the value and increment pointer
	btfsc	STATUS, Z, A	; if W == 0
	return
	call	usart_send
	bra	usart_send_str	; next char

	end
