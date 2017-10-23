        include "config.inc"
        include "usbdef.inc"
        include "usart.inc"

        global  usb_init, usb_service

MAXPACKETSIZE0  equ     8       ; max packet size for EP0

;;; states
POWERED_STATE   equ     0       ; poweron state
DEFAULT_STATE   equ     1       ; state after a USB reset
ADDRESS_STATE   equ     2       ; the device is addressed
CONFIG_STATE    equ     3       ; the device is configured

.usbd1  udata

cnt     res     1               ; counter variable
custat  res     1               ; current copy of USTAT
bufdesc res     4               ; current copy of the EP buffer descriptor
bufdata res     8               ; buffer data
devreq  res     1               ; code of the received request
devconf res     1               ; current configuration
devstat res     1               ; device status (self powered, remote wakeup)

pending_addr    res     1       ; pending addr to assign to the device
uswstat res     1               ; state of the device (POWERED, DEFAULT, ADDRESS, CONFIG)

dptr    res     1               ; descriptor offset
bleft   res     1               ; descriptor length

.usbst  code

usb_init:
        ;; enable the Active Clock Tuning to USB clock
        movlw   1<<ACTSRC
        movwf   ACTCON, A       ; set USB as source
        bsf     ACTCON, ACTEN, A

        ;; prepare the USB module
        clrf    UCON, A         ; disable the USB module
        clrf    UIE, A          ; mask the USB interrupts
        clrf    UIR, A          ; clear the USB interrupt flags
        movlw   1<<UPUEN|1<<FSEN
        movwf   UCFG, A         ; D+pullup | FullSpeed enable
        movlw   1<<USBEN
        movwf   UCON, A         ; enable the USB module

        banksel uswstat
        clrf    uswstat, B      ; device status (DEFAULT, ADDRESS, CONFIG)
        movlw   0xFF
        movwf   devreq, B       ; current request = 0xFF (no request)
        clrf    pending_addr, B ; pending address
        clrf    devconf, B      ; current configuration
        movlw   1
        movwf   devstat, B      ; current status (1 = self powered)

        btfsc   UCON, SE0, A    ; wait until SE0 == 0
        bra     $-2
        return

;;; called to service the USB conditions
usb_service:
        ;; received Start-Of-Frame
        btfsc   UIR, SOFIF, A
        bcf     UIR, SOFIF, A

        ;; received Stall handshake
        btfsc   UIR, STALLIF, A
        bcf     UIR, STALLIF, A

        ;; IDLE condition detected
        btfss   UIR, IDLEIF, A
        bra     usb_service_idle_end
        bcf     UIR, IDLEIF, A
        bsf     UCON, SUSPND, A ; suspend the device
usb_service_idle_end:

        ;; Bus activity detected
        btfss   UIR, ACTVIF, A
        bra     usb_service_actv_end
        btfsc   UCON, SUSPND, A
        bcf     UCON, SUSPND, A ; resume the device
        bcf     UIR, ACTVIF, A
usb_service_actv_end:

        ;; Unmasked error condition
        btfsc   UIR, UERRIF, A
        clrf    UEIR, A

        ;; USB reset condition
        btfss   UIR, URSTIF, A
        bra     usb_service_reset_end

        ;; clear the TRNIF 4 times
        bcf     UIR, TRNIF, A
        bcf     UIR, TRNIF, A
        bcf     UIR, TRNIF, A
        bcf     UIR, TRNIF, A

        ;; disable all the endpoints
        clrf    UEP0, A         ; clear the EP0
        call    clear_endpoints ; clear the other EPs

        ;; setup the EP0 Buffer Descriptor Table (OUT && IN)
        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; maxPacketSize0
        movlw   LOW(USBDATA)    ;
        movwf   BD0OAL, B       ; OUT buffer address LSB
        movlw   HIGH(USBDATA)   ;
        movwf   BD0OAH, B       ; OUT buffer address MSB
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD0OST, B       ; UOWN, DTS enabled

        movlw   LOW(USBDATA + MAXPACKETSIZE0)
        movwf   BD0IAL, B       ; IN buffer address LSB
        movlw   HIGH(USBDATA + MAXPACKETSIZE0)
        movwf   BD0IAH, B       ; IN buffer address MSB
        movlw   1<<DTSEN
        movwf   BD0IST, B       ; buffer owned by the firmware, data toggle enable

        movlw   1<<EPHSHK|1<<EPOUTEN|1<<EPINEN
        movwf   UEP0, A         ; enable input, output, setup, handshake

        clrf    UIR, A          ; clear the interrupt flags
        clrf    UADDR, A        ; reset the device address to 0

        movlw   0x9F
        movwf   UEIE, A         ; enable all the interrupts

        banksel uswstat
        movlw   DEFAULT_STATE
        movwf   uswstat, B      ; set the DEFAULT state
        clrf    devconf, B      ; device configuration cleared
        movlw   1
        movwf   devstat, B      ; Self-Powered !Remote-Wakeup
usb_service_reset_end:

        ;; Transaction complete
        btfss   UIR, TRNIF, A
        bra     usb_service_trn_end
        movlw   HIGH(BD0OST)
        movwf   FSR0H, A        ; FSR0H = MSB 0x400
        movf    USTAT, W, A     ; content of USTAT
        movwf   custat, B       ; save a copy of USTAT
        andlw   0x7C            ; mask out EP and DIRECTION (OUT, IN)
        movwf   FSR0L, A        ; FSR0L = LSB into the endpoint

        ;; save the BD registers in the bufdesc buffer
        banksel bufdesc
        movf    POSTINC0, W, A
        movwf   bufdesc+0, B
        movf    POSTINC0, W, A
        movwf   bufdesc+1, B
        movf    POSTINC0, W, A
        movwf   bufdesc+2, B
        movf    POSTINC0, W, A
        movwf   bufdesc+3, B

        bcf     UIR, TRNIF, A   ; advance the USTAT FIFO

        movf    bufdesc+0, W, B
        andlw   0x3C            ; mask out the PID
        xorlw   0x0D<<2         ; SETUP
        btfsc   STATUS, Z, A
        bra     usb_setup_token
        xorlw   (0x09<<2)^(0x0D<<2) ; IN
        btfsc   STATUS, Z, A
        bra     usb_in_token
        xorlw   (0x01<<2)^(0x09<<2) ; OUT
        btfsc   STATUS, Z, A
        bra     usb_out_token
usb_service_trn_end:
        return

        ;; Clear the endpoint from 1 to 15
        ;; but skip the EP0
clear_endpoints:
        clrf    UEP1, A
        clrf    UEP2, A
        clrf    UEP3, A
        clrf    UEP4, A
        clrf    UEP5, A
        clrf    UEP6, A
        clrf    UEP7, A
        clrf    UEP8, A
        clrf    UEP9, A
        clrf    UEP10, A
        clrf    UEP11, A
        clrf    UEP12, A
        clrf    UEP13, A
        clrf    UEP14, A
        clrf    UEP15, A
        return

        ;; called whenever we encounter an error
        ;; with control packets to EP0
error_recovery:
        banksel devreq
        movlw   0xFF
        movwf   devreq, B       ; set devreq to 0xFF
        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; set the bytecount to MAXPACKETSIZE0
        movlw   1<<UOWN|1<<BSTALL
        movwf   BD0IST, B       ; stall the EP0 IN
        movwf   BD0OST, B       ; stall the EP0 OUT
        return

usb_setup_token:
        call    print_nl
        movlw   'S'
        call    usart_send

        ;; copy the received packet into bufdata
        banksel bufdata
        movf    bufdesc+2, W, B ; LSB of the address
        movwf   FSR0L, A
        movf    bufdesc+3, W, B ; MSB of the address
        movwf   FSR0H, A        ; FSR0 points to the buffer for EP0
        lfsr    FSR1, bufdata   ; FSR1 points to the private bufdata

        ;; movlw   MAXPACKETSIZE0
        movf    bufdesc+1, W, B ; load the byte count
        sublw   MAXPACKETSIZE0
        movlw   MAXPACKETSIZE0
        btfss   STATUS, C, A    ; avoid overflows
        movf    bufdesc+1, W, B
        movwf   cnt, B
usb_setup_copy:
        movf    POSTINC0, W, A
        movwf   POSTINC1, A
        decfsz  cnt, F, B
        bra     usb_setup_copy

        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; reset the byte count
        movlw   1<<DTSEN
        movwf   BD0IST, B       ; make the buffer available to the firmware

        ;; check the request type
        banksel bufdata
        movlw   1<<UOWN|1<<DTSEN
        btfsc   bufdata+0, 7, B ; if bit7 of bmRequestType != 0
        bra     usb_setup_token_1
        movf    bufdata+6, W, B
        iorwf   bufdata+7, W, B
        movlw   1<<UOWN|1<<DTSEN
        btfss   STATUS, Z, A
        iorlw   1<<DTS          ; if wLength == 0 set DATA1
usb_setup_token_1:
        banksel BD0OST
        movwf   BD0OST, B

        bcf     UCON, PKTDIS, A ; re-enable the SIE token and packet processing

        banksel devreq
        movlw   0xFF
        movwf   devreq, B       ; set the device request to NO_REQUEST

        movf    bufdata+0, W, B ; bmRequestType
        andlw   0x60            ; get the request type (D5..D6)
        btfsc   STATUS, Z, A
        bra     standard_requests
        xorlw   1<<5            ; 1 = class request
        btfsc   STATUS, Z, A
        bra     class_requests
        xorlw   2<<5 ^ 1<<5     ; 2 = vendor request
        btfsc   STATUS, Z, A
        bra     vendor_requests
        bra     error_recovery  ; error condition

        ;; process the standard requests
standard_requests:
        movlw   'S'
        call    usart_send
        movf    bufdata+1, W, B
        movwf   devreq, B
        addlw   255 - 12
        addlw   (12 - 0) + 1
        bnc     standard_requests_err ; check if devreq is in range 0..12
        ;; send the R number
        movlw   'R'
        call    usart_send
        lfsr    FSR0, devreq
        call    print_h8
        movlw   ' '
        call    usart_send
        movlw   UPPER(standard_requests_table)
        movwf   PCLATU, A
        movlw   HIGH(standard_requests_table)
        movwf   PCLATH, A
        rlncf   devreq, W, B
        addwf   PCL, F, A
standard_requests_table:
        bra     get_status            ; GET_STATUS        (0)
        bra     clear_feature         ; CLEAR_FEATURE     (1)
        bra     standard_requests_err ; RESERVED          (2)
        bra     set_feature           ; SET_FEATURE       (3)
        bra     standard_requests_err ; RESERVED          (4)
        bra     set_address           ; SET_ADDRESS       (5)
        bra     get_descriptor        ; GET_DESCRIPTOR    (6)
        bra     standard_requests_err ; SET_DESCRIPTOR    (7)
        bra     get_configuration     ; GET_CONFIGURATION (8)
        bra     set_configuration     ; SET_CONFIGURATION (9)
        bra     get_interface         ; GET_INTERFACE    (10)
        bra     set_interface         ; SET_INTERFACE    (11)
        bra     standard_requests_err ; SYNCH_FRAME      (12)
standard_requests_err:
        movlw   'E'
        call    usart_send
        bra     error_recovery  ; error condition

set_address:
        btfsc   bufdata+2, 7, B ; check if the address is legal
        bra     standard_requests_err

        movlw   5
        movwf   devreq, B
        movf    bufdata+2, W, B ; wValue
        movwf   pending_addr, B ; store the address
        banksel BD0IBC
        clrf    BD0IBC, B       ; set the IN byte count to 0
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

get_descriptor:
        movf    bufdata+1, W, B ; bRequest
        movwf   devreq, B       ; store
        movf    bufdata+3, W, B ; wValue
        addlw   -1
        bz      get_descriptor_device
        addlw   -1
        bz      get_descriptor_configuration
        addlw   -1
        bz      get_descriptor_string
        bra     standard_requests_err

get_descriptor_device:
        movlw   LOW(Device-DescriptorBegin)
        bra     send_offset

get_descriptor_configuration:
        movf    bufdata+2, W, B ; wValue
        bnz     standard_requests_err
        movlw   (Configuration1-DescriptorBegin)
        addlw   2
        movwf   dptr, B
        call    Descriptor
        movwf   bleft, B
        movlw   2
        subwf   dptr, F, B
        call    Descriptor
        bra     send_check_length

get_descriptor_string:
        movf    bufdata+2, W, B ; wValue
        bz      get_descriptor_string0
        addlw   -1
        bz      get_descriptor_string1
        addlw   -1
        bz      get_descriptor_string2
        bra     standard_requests_err
get_descriptor_string0:
        movlw   (String0-DescriptorBegin)
        bra     send_offset
get_descriptor_string1:
        movlw   (String1-DescriptorBegin)
        bra     send_offset
get_descriptor_string2:
        movlw   (String2-DescriptorBegin)
        bra     send_offset

get_configuration:
        banksel BD0IAH
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A
        banksel devconf
        movf    devconf, W, B
        movwf   INDF0, A
        banksel BD0IBC
        movlw   0x01
        movwf   BD0IBC, B       ; byte count = 1
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

set_configuration:
        movf    bufdata+3, W, B ; wValue
        addlw   255 - 1         ; error if config number > 1
        bc      standard_requests_err

        ;; clear all the EP control registers except EP0
        call    clear_endpoints

        ;; save the configuration number in devconf
        movf    bufdata+3, W, B
        movwf   devconf, B

        ;; set the swstat accordingly
        movlw   ADDRESS_STATE
        btfss   STATUS, Z, A
        movlw   CONFIG_STATE
        movwf   uswstat, B

        ;; send the reply packet
        banksel BD0IBC
        clrf    BD0IBC, B       ; byte count = 0
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

get_interface:
        movf    uswstat, W, B
        sublw   CONFIG_STATE
        bnz     standard_requests_err
        movf    bufdata+3, W, B
        addlw   255 - 1
        bc      standard_requests_err

        ;; send the reply packet
        banksel BD0IAH
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A
        clrf    INDF0           ; always zero the bAlternateSetting
        movlw   1
        movwf   BD0IBC, B       ; byte count = 1
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

set_interface:
        movf    uswstat, W, B
        sublw   CONFIG_STATE
        bnz     standard_requests_err
        movf    bufdata+3, W, B
        addlw   255 - 1
        bc      standard_requests_err

        ;; send the reply packet
        banksel BD0IBC
        clrf    BD0IBC, B       ; byte count = 0
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

get_status:
        ;; prepare the response
        banksel BD0IAH
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A        ; FSR0 = EP0 IN buffer

        banksel bufdata
        movf    bufdata+0, W, B ; bmRequestType
        andlw   0x1F
        bz      get_status_device
        addlw   -1
        bz      get_status_interface
        addlw   -1
        bz      get_status_endpoint
get_status_error:
        bra     error_recovery
get_status_device:
        movf    devstat, W, B
        movwf   POSTINC0, A
        bra     get_status_send
get_status_interface:
        clrf    POSTINC0, A
        bra     get_status_send
get_status_endpoint:
        call    check_ep_direction
        bc      get_status_error
        call    load_ep_bdt
        movf    INDF1, W, A
        andlw   0x04
        movwf   INDF0, A
        rrncf   INDF0, F, A
        rrncf   POSTINC0, F, A  ; shift the stall bit to the left
        bra     get_status_send
get_status_send:
        clrf    INDF0, A
        banksel BD0IBC
        movlw   0x02
        movwf   BD0IBC, B       ; byte count = 2
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

clear_feature:
set_feature:
        movf    bufdata+0, W, A
        andlw   0x1F
        bz      xx_feature_device
        addlw   -1
        bz      xx_feature_endpoint
xx_feature_err:
        bra     error_recovery
xx_feature_device:
        movf    bufdata+2, W, A
        addlw   -1
        bnz     xx_feature_err
        movf    bufdata+1, W, B ; wValue (request type)
        sublw   1
        bcf     devstat, 1, B   ; CLEAR_FEATURE = no remote_wakeup
        btfss   STATUS, Z ,A
        bsf     devstat, 1, B   ; SET_FEATURE = activate remote_wakeup
xx_feature_send:
        banksel BD0IBC
        clrf    BD0IBC, B
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return
xx_feature_endpoint:
        call    check_ep_direction
        bc      xx_feature_err
        call    load_ep_bdt
        btfss   bufdata+4, 7, B
        bra     xx_feature_endpoint_out
xx_feature_endpoint_in:
        movf    bufdata+1, W, B ; wValue (request type)
        sublw   1
        movlw   0x00            ; CLEAR_FEATURE = clear stall condition
        btfss   STATUS, Z, A
        movlw   0x84            ; SET_FEATURE = set stall condition
        movwf   INDF1, A
        bra     xx_feature_send
xx_feature_endpoint_out:
        movf    bufdata+1, W, B ; wValue (request type)
        sublw   1
        movlw   0x88            ; CLEAR_FEATURE = clear the stall
        btfss   STATUS, Z, A
        movlw   0x84            ; SET_FEATURE = set the stall
        movwf   INDF1, A
        bra     xx_feature_send

        ;; process the class requests
class_requests:
        movlw   'C'
        call    usart_send
        bra     error_recovery  ; error condition

        ;; process the vendor requests
vendor_requests:
        movlw   'V'
        call    usart_send
        bra     error_recovery  ; error condition

        ;; process the IN (send to the host) token
usb_in_token:
        banksel custat
        movf    custat, W, B
        andlw   0x18            ; get the EP bits
        bz      usb_in_ep0
        addlw   -(1<<3)
        bz      usb_in_ep1
        addlw   -(1<<3)
        bz      usb_in_ep2
usb_in_ep1:
usb_in_ep2:
        return

usb_in_ep0:
        movf    devreq, W, B
        xorlw   0x05
        bz      usb_in_ep0_setaddress
        xorlw   0x06^0x05
        bz      usb_in_ep0_getdescriptor
        return
usb_in_ep0_setaddress:
        movf    pending_addr, W, B
        movwf   UADDR, A        ; save the pending addr to the USB UADDR
        movlw   DEFAULT_STATE   ; UADDR == 0 -> the device is in default state
        btfss   STATUS, Z, A
        movlw   ADDRESS_STATE   ; UADDR != 0 -> the device is in addressed state
        movwf   uswstat, B
        return
usb_in_ep0_getdescriptor:
        bra     send_descriptor_packet

        ;; process the OUT (receive from host) token
usb_out_token:
        banksel custat
        movf    custat, W, B
        andlw   0x18
        bz      usb_out_ep0
        addlw   -1<<3
        bz      usb_out_ep1
        addlw   -1<<3
        bz      usb_out_ep2
usb_out_ep1:
usb_out_ep2:
        return

usb_out_ep0:
        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; MAXPACKETSIZE0 bytes
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD0OST, B       ; UOWN, DATA0
        clrf    BD0IBC, B       ; 0 bytes
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

        ;; check the direction of the endpoint request
        ;; (uses FSR1)
        ;; set the Carry flag in case of mismatches
check_ep_direction:
        lfsr    FSR1, UEP0
        movf    bufdata+4, W, B
        andlw   0x0F
        addwf   FSR1L, F, A
        btfsc   STATUS, C, A
        incf    FSR1H, F, A
        bcf     STATUS, C, A    ; no error by default
        btfss   bufdata+4, 7, B
        bra     check_ep_direction_out
        btfss   PLUSW1, EPINEN, A
        bsf     STATUS, C, A
        return
check_ep_direction_out
        btfss   PLUSW1, EPOUTEN, A
        bsf     STATUS, C, A
        return

        ;; load BDT into FSR1
load_ep_bdt:
        movf    bufdata+4, W, B ; wIndex (endpoint)
        andlw   0x8F
        movwf   FSR1L, A
        rlncf   FSR1L, F, A
        rlncf   FSR1L, F, A
        rlncf   FSR1L, F, A     ; FSR1L has the offset into BD0OST
        movlw   HIGH(BD0OST)
        movwf   FSR1H, A
        movlw   LOW(BD0OST)
        addwf   FSR1L, F, A
        btfsc   STATUS, C, A
        incf    FSR1H, F, A     ; FSR1 points to BDn[OI]ST
        return

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

print_nl:
        movlw   '\r'
        call    usart_send
        movlw   '\n'
        bra     usart_send

send_offset:
        movwf   dptr, B         ; offset of the data from the beginning
        call    Descriptor
        movwf   bleft, B        ; length of the bytes to send
        call    print_nl
        movlw   'P'
        call    usart_send
        lfsr    FSR0, bleft
        call    print_h8
        movlw   ' '
        call    usart_send

send_check_length:
        movf    bufdata+7, W, B
        bnz     send_descriptor_packet
        movf    bleft, W, B
        subwf   bufdata+6, W, B ; if (wLength < bleft)
        bc      send_descriptor_packet
        movf    bufdata+6, W, B ;   bleft = wLength;
        movwf   bleft, B        ;
        movlw   'C'
        call    usart_send
        lfsr    FSR0, bleft
        call    print_h8
        movlw   ' '
        call    usart_send

send_descriptor_packet:
        banksel bleft
        movf    bleft, W, B
        sublw   MAXPACKETSIZE0
        movlw   MAXPACKETSIZE0
        bnc     send_descriptor_packet_2
        movlw   0xFF            ;
        movwf   devreq, B       ; devreq = 0xFF
        movf    bleft, W, B     ; cnt = bleft
send_descriptor_packet_2:
        subwf   bleft, F, B
        movwf   cnt, B

        banksel BD0IBC
        movwf   BD0IBC, B       ; byte count to send
        addlw   '0'
        call    usart_send
        movlw   ' '
        call    usart_send
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A        ; FSR0 = pointer to USB RAM

        ;; copy the data from the table
        call    Descriptor      ; somebody could have changed the TBLPTR
        banksel cnt
send_loop:
        tblrd   *+
        movf    TABLAT, W, A
        movwf   POSTINC0, A
        incf    dptr, F, B
        decfsz  cnt, F, B
        bra     send_loop

        ;; send the data
        banksel BD0IST
        movlw   1<<DTS
        xorwf   BD0IST, W, B    ; toggle DATA bit
        andlw   1<<DTS          ; filter it
        iorlw   1<<UOWN|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA[01] bit
        return

        ;; load the data in the offset into the table
        ;; and return the length of the data
Descriptor:
        movlw   UPPER(DescriptorBegin)
        movwf   TBLPTRU, A
        movlw   HIGH(DescriptorBegin)
        movwf   TBLPTRH, A
        movlw   LOW(DescriptorBegin)

        banksel dptr
        addwf   dptr, W, B
        movwf   TBLPTRL, A
        movlw   0
        addwfc  TBLPTRH, F, A
        addwfc  TBLPTRU, F, A
        tblrd   *
        movf    TABLAT, W
        return

.usbtables      CODE_PACK
DescriptorBegin:
Device:
        db      0x12            ; bLength
        db      0x01            ; bDescriptorType = 1 (Device)
        db      0x10, 0x01      ; bcdUSB = USB 2.0
        db      0x00, 0x00, 0x00 ; USB-IF class, subclass, protocol
        db      MAXPACKETSIZE0  ; maxPacketSize0 for ENDP0
        db      0xD8, 0x04      ; idVendor
        db      0x01, 0x00      ; idProduct
        db      0x00, 0x00      ; bcdDevice
        db      0x01            ; iManufacturer
        db      0x02            ; iProduct
        db      0x00            ; iSerialNumber
        db      0x01            ; bNumConfigurations

Configuration1:
        db      0x09            ; bLength
        db      0x02            ; bDescriptorType = 2 (Configuration)
        db      0x12, 0x00      ; wTotalLength (LSB, MSB)
        db      0x01            ; bNumInterfaces
        db      0x01            ; bConfigurationValue
        db      0x00            ; iConfiguration (not specified)
        db      0xE0            ; bmAttributes = selfPowered | remoteWakeup
        db      0x32            ; bMaxPower = 50 * 2mA = 100mA

Interface1:
        db      0x09            ; bLength
        db      0x04            ; bDescriptorType = 4 (Interface)
        db      0x00            ; bInterfaceNumber
        db      0x00            ; bAlternateSetting (0 = default)
        db      0x00            ; bNumEndpoints (0 additional endpoints)
        db      0xFF            ; bInterfaceClass (0xFF = vendor specified)
        db      0x00            ; bInterfaceSubClass
        db      0xFF            ; bInterfaceProtocol (0xFF = vendor specified)
        db      0x00            ; iInterface (0x00 = no string)

String0:
        db      String1-String0 ; bLength
        db      0x03            ; bDescriptorType = 3 (String)
        db      0x09, 0x04      ; wLangID[0] (LSB, MSB)

String1:
        db      String2-String1 ; bLength
        db      0x03            ; bDescriptorType = 3 (String)
        db      'M', 0
        db      'i', 0
        db      'c', 0
        db      'r', 0
        db      'o', 0
        db      'c', 0
        db      'h', 0
        db      'i', 0
        db      'p', 0
        db      ' ', 0
        db      'T', 0
        db      'e', 0
        db      'c', 0
        db      'h', 0
        db      'n', 0
        db      'o', 0
        db      'l', 0
        db      'o', 0
        db      'g', 0
        db      'y', 0
        db      ',', 0
        db      ' ', 0
        db      'I', 0
        db      'n', 0
        db      'c', 0
        db      '.', 0

String2:
        db      DescriptorEnd-String2 ; bLength
        db      0x03            ; bDescriptorType = 3 (String)
        db      'f', 0
        db      'u', 0
        db      'n', 0
        db      'n', 0
        db      'y', 0
        db      'd', 0
        db      'o', 0
        db      'g', 0
        db      ' ', 0
        db      'f', 0
        db      'i', 0
        db      'r', 0
        db      'm', 0
        db      'w', 0
        db      'a', 0
        db      'r', 0
        db      'e', 0
DescriptorEnd:

        END
