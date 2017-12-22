        include "config.inc"
        include "usbdef.inc"
        include "usart.inc"

        global  usb_init, usb_service

;; #define USARTDEBUG              ; defined if usart debugging is enabled

MAXPACKETSIZE0  equ     8       ; max packet size for EP0

;;; states
DEFAULT_STATE   equ     0       ; state after a USB reset
ADDRESS_STATE   equ     1       ; the device is addressed
CONFIG_STATE    equ     2       ; the device is configured

;; constants
MAX_CONFIG      equ     1       ; number of configurations
MAX_INTERFACES  equ     1       ; number of interfaces
MAX_ENDPOINT    equ     2       ; number of endpoints (beyond EP0)

.usbd1  udata

cnt     res     1               ; counter variable
custat  res     1               ; current copy of USTAT
bufdesc res     4               ; current copy of the EP buffer descriptor
bufdata res     8               ; buffer data
devreq  res     1               ; code of the received request
devconf res     1               ; current configuration
devstat res     1               ; device status (self powered, remote wakeup)

penaddr res     1               ; pending addr to assign to the device
uswstat res     1               ; state of the device (DEFAULT, ADDRESS, CONFIG)

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
        movlw   DEFAULT_STATE
        movwf   uswstat, B      ; device status (DEFAULT, ADDRESS, CONFIG)
        movlw   0xFF
        movwf   devreq, B       ; current request = 0xFF (no request)
        clrf    penaddr, B      ; pending address
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
        banksel custat
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

        ;; send ack packet on successful transaction
ep0_send_ack:
        movlw   0
        ;; send data packet made of W bytes
ep0_send_data:
        banksel BD0IBC
        movwf   BD0IBC, B
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

        ;; stall input and output of EP0
        ;; whenever we encounter an error
ep0_stall_error:
#ifdef USARTDEBUG
        movlw   'E'
        call    usart_send
#endif
        banksel devreq
        movlw   0xFF
        movwf   devreq, B       ; set devreq to 0xFF
        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; prepare to receive the next packet
        movlw   1<<UOWN|1<<BSTALL
        movwf   BD0IST, B       ; issue a Stall on EP0 IN
        movwf   BD0OST, B       ; and on EP0 OUT
        return

usb_setup_token:
#ifdef USARTDEBUG
        call    usart_send_nl
        movlw   'S'
        call    usart_send
#endif

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
        addlw   -(1<<5)         ; 1 == class request
        btfsc   STATUS, Z, A
        bra     class_requests
        addlw   -(1<<5)         ; 2 == vendor_request
        btfsc   STATUS, Z, A
        bra     vendor_requests
        bra     ep0_stall_error  ; error condition

        ;; process the standard requests
standard_requests:
#ifdef USARTDEBUG
        movlw   'S'
        call    usart_send
#endif
        movf    bufdata+1, W, B
        movwf   devreq, B
        addlw   255 - 12
        addlw   (12 - 0) + 1
        btfss   STATUS, C, A
        bra     ep0_stall_error ; check if devreq is in range 0..12
#ifdef USARTDEBUG
        ;; send the R number
        movlw   'R'
        call    usart_send
        lfsr    FSR0, devreq
        call    usart_send_h8
        movlw   ' '
        call    usart_send
#endif
        movlw   UPPER(standard_requests_table)
        movwf   PCLATU, A
        movlw   HIGH(standard_requests_table)
        movwf   PCLATH, A
        rlncf   devreq, W, B
        addlw   LOW(standard_requests_table)
        movwf   PCL, A

set_address:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error
        btfsc   bufdata+2, 7, B ; check if the address is legal
        bra     ep0_stall_error
        movf    bufdata+2, W, B ; wValue
        movwf   penaddr, B      ; store the address
        bra     ep0_send_ack

get_descriptor:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        movf    bufdata+1, W, B ; bRequest
        movwf   devreq, B       ; store
        movf    bufdata+3, W, B ; wValueHigh
        addlw   -1              ; 0x01 - Device
        bz      get_descriptor_device
        addlw   -1              ; 0x02 - Configuration
        bz      get_descriptor_configuration
        addlw   -1              ; 0x03 - String
        bz      get_descriptor_string
        addlw   -30             ; 0x21 - HID
        bz      get_descriptor_hid
        addlw   -1              ; 0x22 - HID Report
        bz      get_descriptor_hidreport
        bra     ep0_stall_error

get_descriptor_device:
        movlw   LOW(Device-DescriptorBegin)
        bra     send_with_length

get_descriptor_configuration:
        movf    bufdata+2, W, B ; wValue
        btfss   STATUS, Z, A
        bra     ep0_stall_error
        movlw   (Configuration1-DescriptorBegin)
        movwf   dptr, B
        call    Descriptor
        movlw   (Configuration1End-Configuration1)
        movwf   bleft, B
        bra     send_data

get_descriptor_hid:
        movlw   LOW(HIDInterface-DescriptorBegin)
        call    send_with_length

get_descriptor_hidreport:
        movlw   LOW(HIDReport-DescriptorBegin)
        movwf   dptr, B
        call    Descriptor
        movlw   HIDReportEnd-HIDReport
        movwf   bleft, B
        bra     send_data

get_descriptor_string:
        movf    bufdata+2, W, B ; wValue
        bz      get_descriptor_string0
        addlw   -1
        bz      get_descriptor_string1
        addlw   -1
        bz      get_descriptor_string2
        bra     ep0_stall_error
get_descriptor_string0:
        movlw   (String0-DescriptorBegin)
        bra     send_with_length
get_descriptor_string1:
        movlw   (String1-DescriptorBegin)
        bra     send_with_length
get_descriptor_string2:
        movlw   (String2-DescriptorBegin)
        bra     send_with_length

get_configuration:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        banksel BD0IAH
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A
        banksel uswstat
        movlw   ADDRESS_STATE
        subwf   uswstat, W, B   ; if (uswstat == ADDRESS_STATE)
        btfss   STATUS, Z, A    ;   INDF0 = 0;
        movf    devconf, W, B   ; else
        movwf   INDF0, A        ;   INDF0 = devconf;
        movlw   1
        bra     ep0_send_data

set_configuration:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        movf    bufdata+2, W, B
        sublw   MAX_CONFIG
        btfss   STATUS, C, A
        bra     ep0_stall_error

        ;; clear all the EP control registers except EP0
        call    clear_endpoints

        ;; setup the EP1 Buffer Descriptor Table (OUT && IN)
        banksel BD1IBC
        movlw   8               ; size of the packet
        movwf   BD1IBC, B
        movlw   LOW(USBDATA+16)
        movwf   BD1IAL, B       ; buffer for EP1 (LSB)
        movlw   HIGH(USBDATA+16)
        movwf   BD1IAH, B       ; buffer for EP1 (MSB)
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD1IST, B       ; UOWN, DTS enabled
        movlw   1<<EPHSHK|1<<EPINEN
        movwf   UEP1, A         ; enable input, handshake

        banksel BD2OBC
        movlw   8               ; size of the packet
        movwf   BD2OBC, B
        movlw   LOW(USBDATA+24)
        movwf   BD2OAL, B       ; buffer for EP2 (LSB)
        movlw   HIGH(USBDATA+24)
        movwf   BD2OAH, B       ; buffer for EP2 (MSB)
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD2OST, B       ; buffer owned by the firmware, data toggle enable
        movlw   1<<EPHSHK|1<<EPOUTEN
        movwf   UEP2, A         ; enable output, handshake

        ;; save the configuration number in devconf
        movf    bufdata+2, W, B ; wValue
        movwf   devconf, B      ; devconf = wValue
        movlw   ADDRESS_STATE
        btfss   STATUS, Z, A
        movlw   CONFIG_STATE
        movwf   uswstat, B      ; uswstat = (devconf == 0) ? ADDRESS_STATE : CONFIG_STATE

        bra     ep0_send_ack

get_interface:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        movlw   MAX_INTERFACES
        subwf   bufdata+4, W, B ; wIndex
        btfss   STATUS, C, A
        bra     ep0_stall_error

        ;; send the reply packet
        banksel BD0IAH
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A
        clrf    INDF0           ; always zero the bAlternateSetting
        movlw   1
        bra     ep0_send_data

set_interface:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        movlw   MAX_INTERFACES
        subwf   bufdata+4, W, B ; wIndex
        btfss   STATUS, C, A
        bra     ep0_stall_error
        bra     ep0_send_ack

get_status:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     get_status_error
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
        bra     ep0_stall_error
get_status_device:
        movf    devstat, W, B
        movwf   POSTINC0, A
        bra     get_status_send
get_status_interface:
        movlw   ADDRESS_STATE
        subwf   uswstat, W, B
        bz      get_status_error ; request not allowed in ADDRESS_STATE
        movlw   1                ; max number of interfaces
        subwf   bufdata+4, W, B  ; wIndex (interface number)
        bc      get_status_error ; interface doesn't exist
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
        movlw   0x02
        bra     ep0_send_data

clear_feature:
set_feature:
        call    check_request_acl ; ACL check
        bc      xx_feature_err
        movf    bufdata+0, W, B ; bmRequestType
        andlw   0x1F
        bz      xx_feature_dev
        addlw   -1
        bz      xx_feature_send
        addlw   -1
        bz      xx_feature_ep
xx_feature_err:
        bra     ep0_stall_error
xx_feature_dev:
        movf    bufdata+2, W, B ; ensure the feature is Remote Wakeup
        bz      xx_feature_err
        movf    bufdata+1, W, B ; wValue (request type)
        sublw   1
        bcf     devstat, 1, B   ; CLEAR_FEATURE = no remote_wakeup
        btfss   STATUS, Z ,A
        bsf     devstat, 1, B   ; SET_FEATURE = activate remote_wakeup
        bra     xx_feature_send
xx_feature_ep:
        movf    bufdata+4, W, B
        andlw   0x7F
        bz      xx_feature_send ; don't stall EP0
        call    check_ep_direction
        bc      xx_feature_err
        call    load_ep_bdt     ; load BDT into FSR1
        btfss   bufdata+4, 7, B
        movf    bufdata+1, W, B ; wValue (request type)
        sublw   1
        movlw   0x88            ; CLEAR_FEATURE = clear stall condition
        btfss   STATUS, Z, A
        movlw   0x84            ; SET_FEATURE = set stall condition
        movwf   INDF1, A
xx_feature_send:
        bra     ep0_send_ack

        ;; process the class requests
class_requests:
#ifdef USARTDEBUG
        movlw   'C'
        call    usart_send
#endif
        movf    bufdata+1, W, B
        addlw   -0x0a           ; SET_IDLE
        bz      set_idle
        bra     ep0_stall_error
set_idle:
class_requests_ack:
        bra     ep0_send_ack

        ;; process the vendor requests
vendor_requests:
#ifdef USARTDEBUG
        movlw   'V'
        call    usart_send
#endif
        movf    bufdata+1, W, B ; bRequest
        bz      vendor_set
        bra     ep0_stall_error
vendor_set:
        movf    bufdata+2, W, B ; wValue
        movwf   LATB, A
vendor_send:
        bra     ep0_send_ack

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
        return
usb_in_ep1:
#ifdef USARTDEBUG
        movlw   '<'
        call    usart_send
#endif
        banksel BD1IST
        movlw   8
        movwf   BD1IBC, B
        movlw   1<<DTS
        xorwf   BD1IST, W, B    ; toggle DATA bit
        andlw   1<<DTS          ; filter it
        iorlw   1<<UOWN|1<<DTSEN
        movwf   BD1IST, B       ; UOWN, DATA1
        return
usb_in_ep2:
        return                  ; ep2 is an OUT endpoint

usb_in_ep0:
        movf    devreq, W, B
        addlw   -5              ; 5 = set_address
        bz      usb_in_ep0_setaddress
        addlw   -1              ; 6 = get_descriptor
        bz      usb_in_ep0_getdescriptor
        return
usb_in_ep0_setaddress:
        movf    penaddr, W, B
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
        addlw   -(1<<3)
        bz      usb_out_ep1
        addlw   -(1<<3)
        bz      usb_out_ep2
        return
usb_out_ep1:
        return                  ; ep1 is an IN endpoint
usb_out_ep2:
#ifdef USARTDEBUG
        movlw   '>'
        call    usart_send
#endif
        banksel BD2OST
        movlw   1<<DTS
        xorwf   BD2OST, W, B    ; toggle DATA bit
        andlw   1<<DTS          ; filter it
        iorlw   1<<UOWN|1<<DTSEN
        movwf   BD2OST, B
        return

usb_out_ep0:
        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; MAXPACKETSIZE0 bytes
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD0OST, B       ; UOWN, DATA0
        bra     ep0_send_ack

        ;; check if the request is allowed for each state
check_request_acl:
        banksel bufdata
        movf    bufdata+1, W, B
        addlw   255 - 12
        addlw   (12 - 0) + 1
        bnc     check_request_err
        movlw   UPPER(check_request_table)
        movwf   PCLATU, A
        movlw   HIGH(check_request_table)
        movwf   PCLATH, A
        rlncf   bufdata+1, W, B
        addlw   LOW(check_request_table)
        movwf   PCL, A
check_request_err:
        bsf     STATUS, C, A
        return
check_allow_default:
        movlw   DEFAULT_STATE
        bra     check_request_ok
check_allow_onlyep0:
        movf    bufdata+0, W, B ; bmRequestType
        andlw   0x1F            ; W = recipient (device=0, interface=1, endpoint=2)
        addlw   -2
        bnz     check_allow_addressed
        movlw   ADDRESS_STATE
        subwf   uswstat, W, B   ; set the C flag
        movf    bufdata+4, W, B ; if the request is for ep (C flag unaffected)
        andlw   0x0F            ; (C flag unaffected)
        bnz     check_request_err
        bra     check_request_toggle
check_allow_addressed:
        movlw   ADDRESS_STATE
        bra     check_request_ok
check_allow_configured:
        movlw   CONFIG_STATE
check_request_ok:
        subwf   uswstat, W, B
check_request_toggle:
        btg     STATUS, C, A    ; C = (C==1)?0:1
        return

        ;; check the direction of the endpoint request
        ;; (uses FSR1)
        ;; set the Carry flag in case of mismatches
check_ep_direction:
        lfsr    FSR1, UEP0
        movf    bufdata+4, W, B ; D7 = direction, D3..D0 = endpoint
        andlw   0x7F
        sublw   MAX_ENDPOINT    ; check if EP exists
        bnc     check_ep_direction_err
        sublw   MAX_ENDPOINT
        addwf   FSR1L, F, A
        btfsc   STATUS, C, A
        incf    FSR1H, F, A
        bcf     STATUS, C, A    ; no error by default
        btfss   bufdata+4, 7, B ; bit7 set if direction == IN
        bra     check_ep_direction_out
        btfss   PLUSW1, EPINEN, A
        bra     check_ep_direction_err
check_ep_direction_out:
        btfss   PLUSW1, EPOUTEN, A
check_ep_direction_err:
        bsf     STATUS, C, A
        return

        ;; load BDT into FSR1
load_ep_bdt:
        movlw   HIGH(BD0OST)
        movwf   FSR1H, A
        movf    bufdata+4, W, B ; wIndex (endpoint)
        andlw   0x8F            ; filter out D7 and D3..D0
        movwf   FSR1L, A
        rlncf   FSR1L, F, A     ; 0 0 0 D3 D2 D1 D0 D7
        rlncf   FSR1L, F, A     ; 0 0 D3 D2 D1 D0 D7 0
        rlncf   FSR1L, F, A     ; 0 D2 D2 D1 D0 D7 0 0
        movlw   LOW(BD0OST)
        addwf   FSR1L, F, A     ; add the low address of BDT
        btfsc   STATUS, C, A
        incf    FSR1H, F, A     ; FSR1 points to BDn[OI]ST
        return

        ;; send the data when
        ;; the first byte of the data is the length
send_with_length:
        movwf   dptr, B         ; offset of the data from the beginning
        call    Descriptor
        movwf   bleft, B        ; length of the bytes to send
#ifdef USARTDEBUG
        call    usart_send_nl
        movlw   'P'
        call    usart_send
        lfsr    FSR0, bleft
        call    usart_send_h8
        movlw   ' '
        call    usart_send
#endif

        ;; send the data in TABLAT
        ;; until bleft is zero
send_data:
        movf    bufdata+7, W, B
        bnz     send_descriptor_packet
        movf    bleft, W, B
        subwf   bufdata+6, W, B ; if (wLength < bleft)
        bc      send_descriptor_packet
        movf    bufdata+6, W, B ;   bleft = wLength;
        movwf   bleft, B        ;

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
#ifdef USARTDEBUG
        addlw   '0'
        call    usart_send
        movlw   ' '
        call    usart_send
#endif
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

.usbjumptables  code    0x300
standard_requests_table:
        bra     get_status            ; GET_STATUS        (0)
        bra     clear_feature         ; CLEAR_FEATURE     (1)
        bra     ep0_stall_error       ; RESERVED          (2)
        bra     set_feature           ; SET_FEATURE       (3)
        bra     ep0_stall_error       ; RESERVED          (4)
        bra     set_address           ; SET_ADDRESS       (5)
        bra     get_descriptor        ; GET_DESCRIPTOR    (6)
        bra     ep0_stall_error       ; SET_DESCRIPTOR    (7)
        bra     get_configuration     ; GET_CONFIGURATION (8)
        bra     set_configuration     ; SET_CONFIGURATION (9)
        bra     get_interface         ; GET_INTERFACE    (10)
        bra     set_interface         ; SET_INTERFACE    (11)
        bra     ep0_stall_error       ; SYNCH_FRAME      (12)

check_request_table:
        bra     check_allow_onlyep0    ; GET_STATUS        (0)
        bra     check_allow_onlyep0    ; CLEAR_FEATURE     (1)
        bra     check_request_err      ; RESERVED          (2)
        bra     check_allow_onlyep0    ; SET_FEATURE       (3)
        bra     check_request_err      ; RESERVED          (4)
        bra     check_allow_default    ; SET_ADDRESS       (5)
        bra     check_allow_default    ; GET_DESCRIPTOR    (6)
        bra     check_allow_addressed  ; SET_DESCRIPTOR    (7)
        bra     check_allow_addressed  ; GET_CONFIGURATION (8)
        bra     check_allow_addressed  ; SET_CONFIGURATION (9)
        bra     check_allow_configured ; GET_INTERFACE    (10)
        bra     check_allow_configured ; SET_INTERFACE    (11)
        bra     check_allow_configured ; SYNCH_FRAME      (12)

.usbtables      CODE_PACK

#define RAWHID_USAGE_PAGE       0xFFAB
#define RAWHID_USAGE            0x0200

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
        db      9               ; bLength
        db      2               ; bDescriptorType = 2 (Configuration)
        db      LOW(Configuration1End-Configuration1)  ; wTotalLength (LSB)
        db      HIGH(Configuration1End-Configuration1) ; wTotalLength (MSB)
        db      1               ; bNumInterfaces
        db      1               ; bConfigurationValue
        db      0               ; iConfiguration (not specified)
        db      0xC0            ; bmAttributes = selfPowered
        db      50              ; bMaxPower = 50 * 2mA = 100mA

Interface1:
        db      9               ; bLength
        db      4               ; bDescriptorType (Interface == 4)
        db      0               ; bInterfaceNumber (interface == 0)
        db      0               ; bAlternateSetting (default == 0)
        db      2               ; bNumEndpoints (0 additional endpoints)
        db      0x03            ; bInterfaceClass (0x03 == HID)
        db      0x00            ; bInterfaceSubClass (0 == None, 1 = Boot)
        db      0x00            ; bInterfaceProtocol (0 == None, 1 = Keyboard, 2 = Mouse)
        db      0               ; iInterface (0x00 = no string)

HIDInterface:
        db      9               ; bLength
        db      0x21            ; bDescriptorType (HID == 0x21)
        db      0x11, 0x01      ; bcdHID spec (1.11)
        db      0               ; bCountryCode
        db      1               ; bNumDescriptors
        db      0x22            ; bDescriptorType (REPORT == 0x22)
        db      LOW(HIDReportEnd-HIDReport)  ; wDescriptorLength (LSB)
        db      HIGH(HIDReportEnd-HIDReport) ; wDescriptorLength (MSB)

EPDesc1:
        db      7               ; bLength
        db      5               ; bDescriptorType (endpoint == 5)
        db      0x81            ; bEndpointAddress (0x80 == IN, EP1)
        db      0x03            ; bmAttributes (0x03 = interrupt)
        db      0x08, 0x00      ; wMaxPacketSize (LSB, MSB; 8 bytes)
        db      100             ; bInterval

EPDesc2:
        db      7               ; bLength
        db      5               ; bDescriptorType (endpoint == 5)
        db      0x02            ; bEndpointAddress (OUT, EP2)
        db      0x03            ; bmAttributes (0x03 = interrupt)
        db      0x08, 0x00      ; wMaxPacketSize (8 bytes)
        db      100             ; bInterval
Configuration1End:

HIDReport:
        db      0x06, LOW(RAWHID_USAGE_PAGE), HIGH(RAWHID_USAGE_PAGE) ; Usage Page 0xFF00..0xFFFF
        db      0x0A, LOW(RAWHID_USAGE), HIGH(RAWHID_USAGE)           ; Usage      0x0100..0xFFFF
        db      0xA1, 0x01       ; COLLECTION 1 APPLICATION
        db      0x75, 0x08       ; report size = 8 bits
        db      0x15, 0x00       ; logical minimum = 0
        db      0x26, 0xFF, 0x00 ; logical maximum = 255
        db      0x95, 8          ; report count
        db      0x09, 0x01       ; usage
        db      0x81, 0x02       ; input (array)
        db      0x95, 8          ; report count
        db      0x09, 0x02       ; usage
        db      0x91, 0x02       ; output (array)
        db      0xC0             ; END COLLECTION
HIDReportEnd:

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
