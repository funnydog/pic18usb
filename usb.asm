        include "config.inc"
        include "usbdef.inc"

        global  usb_init, usb_service, usb_set_epaddr, usb_get_epaddr
        extern  usb_rx_event, usb_tx_event, usb_status_event

MAXPACKETSIZE0  equ     8       ; max packet size for EP0
IREPORT_SIZE    equ     8
OREPORT_SIZE    equ     8

        ;; jump table to [reg] position in the table at the end
jmpto    macro   reg, accs
        local   jump_table_address
        movlw   UPPER(jump_table_address)
        movwf   PCLATU, A
        movlw   HIGH(jump_table_address)
        movwf   PCLATH, A
        rlncf   reg, W, accs
        addlw   LOW(jump_table_address)
        btfsc   STATUS, C, A
        incf    PCLATH, F, A
        btfsc   STATUS, C, A
        incf    PCLATU, F, A
        movwf   PCL, A
jump_table_address:
        endm

        ;; load the offset from DescriptorBegin into offset[0..1]
loff    macro   addr
        banksel offset
        movlw   LOW(addr - DescriptorBegin)
        movwf   offset+0, B
        movlw   HIGH(addr - DescriptorBegin)
        movwf   offset+1, B
        endm

.usbd1  udata

cnt     res     1               ; counter variable
custat  res     1               ; current copy of USTAT
bdcopy  res     4               ; SIE managed buffer descriptor copy
bufdata res     8               ; buffer data
devreq  res     1               ; code of the received request
devconf res     1               ; current configuration
devstat res     1               ; device status (self powered, remote wakeup)

penaddr res     1               ; pending addr to assign to the device
uswstat res     1               ; state of the device (DEFAULT, ADDRESS, CONFIGURED, SUSPENDED)

offset  res     2               ; descriptor offset
bleft   res     1               ; descriptor length

.usbst  code

        ;; usb_init() - enable the USB module
        ;;
        ;; Enable the USB module and setup the data
        ;;
        ;; Return: nothing
usb_init:
        ;; set RB3 as input to sense the VBus voltage
        bsf     TRISB, RB3, A

        ;; enable the Active Clock Tuning to USB clock
        movlw   1<<ACTSRC
        movwf   ACTCON, A       ; set USB as source
        bsf     ACTCON, ACTEN, A

        ;; USB global settings
        clrf    UCON, A         ; disable the USB module
        clrf    UIE, A          ; mask the USB interrupts
        movlw   1<<UPUEN|1<<FSEN
        movwf   UCFG, A         ; D+pullup | FullSpeed enable

        ;; set the device to POWERED state
        banksel uswstat
        clrf    uswstat, B

        ;; set up the endpoint buffer descriptors
        movlw   0x00            ; EP0 - Output
        lfsr    FSR0, USBDATA
        call    usb_set_epaddr
        movlw   0x80            ; EP0 - Input
        lfsr    FSR0, USBDATA+MAXPACKETSIZE0
        call    usb_set_epaddr
        movlw   0x81            ; EP1 - Input
        lfsr    FSR0, USBDATA+MAXPACKETSIZE0*2
        call    usb_set_epaddr
        movlw   0x02            ; EP2 - Output
        lfsr    FSR0, USBDATA+MAXPACKETSIZE0*3
        call    usb_set_epaddr

        ;; initialize the USB RAM
        lfsr    FSR0, USBDATA+MAXPACKETSIZE0*2
        movlw   1               ; the first byte of the EP1 buffer
        movwf   POSTINC0, A     ; is the report number
        movlw   15
        banksel cnt
        movwf   cnt, B
usb_init_loop0:
        clrf    POSTINC0, A
        decfsz  cnt, F, B
        bra     usb_init_loop0
        return

        ;; usb_service() - service the USB engine flags
        ;;
        ;; Service the USB SIE flags
        ;;
        ;; Return: nothing
usb_service:
        banksel uswstat
        movf    uswstat, W, B
        bnz     usb_service_enabled

usb_service_disabled:
        btfss   PORTB, RB3, A
        return
        ;; prepare the USB module
        clrf    UIR, A          ; clear the USB interrupt flags
        movlw   1<<USBEN
        movwf   UCON, A         ; enable the USB module
        movlw   0xFF
        banksel devreq
        movwf   devreq, B       ; current request = 0xFF (no request)
        clrf    penaddr, B      ; pending address
        clrf    devconf, B      ; current configuration
        movlw   1
        movwf   devstat, B      ; current status (1 = self powered)
        btfsc   UCON, SE0, A    ; wait until SE0 == 0
        bra     $-2
        movlw   DEFAULT_STATE
        bra     usb_change_state

usb_service_enabled:
        btfsc   PORTB, RB3, A
        bra     usb_service_flags
usb_service_enabled_loop0:
        bcf     UCON, SUSPND, A ; make sure SUSPND bit is clear
        btfsc   UCON, SUSPND, A
        bra     usb_service_enabled_loop0
        clrf    UCON, A         ; disable the USB module
        movlw   0
        bra     usb_change_state

usb_service_flags:
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
        movlw   SUSPENDED_STATE
        call    usb_status_event
usb_service_idle_end:

        ;; Bus activity detected
        btfss   UIR, ACTVIF, A
        bra     usb_service_actv_end
        btfsc   UCON, SUSPND, A
        bcf     UCON, SUSPND, A ; resume the device
        bcf     UIR, ACTVIF, A
        banksel uswstat
        movf    uswstat, W, B
        call    usb_status_event
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
        call    ep_disable_0_15 ; disable eps from 0 to 15

        ;; setup the EP0 Buffer Descriptor Table (OUT && IN)
        banksel BD0OBC
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; maxPacketSize0
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD0OST, B       ; UOWN, DTS enabled
        movlw   1<<DTSEN
        movwf   BD0IST, B       ; buffer owned by the firmware, data toggle enable

        movlw   1<<EPHSHK|1<<EPOUTEN|1<<EPINEN
        movwf   UEP0, A         ; enable input, output, setup, handshake
        clrf    UIR, A          ; clear the interrupt flags
        clrf    UADDR, A        ; reset the device address to 0
        movlw   0x9F
        movwf   UEIE, A         ; enable all the interrupts

        movlw   DEFAULT_STATE
        call    usb_change_state

        banksel devconf
        clrf    devconf, B      ; device configuration cleared
        movlw   1
        movwf   devstat, B      ; Self-Powered !Remote-Wakeup
usb_service_reset_end:

        ;; Transaction complete
        btfss   UIR, TRNIF, A
        return

        ;; save the BD registers owned by the SIE in the bdcopy buffer
        movf    USTAT, W, A     ; content of USTAT
        banksel custat
        movwf   custat, B       ; save a copy of USTAT
        andlw   0x7C            ; mask out EP and DIRECTION (OUT, IN)
        movwf   FSR0L, A        ; FSR0L = LSB into the endpoint
        movlw   HIGH(BD0OST)
        movwf   FSR0H, A        ; FSR0 now points to the current BDnnSTat
        lfsr    FSR1, bdcopy
        movlw   4
        call    memcpy
        bcf     UIR, TRNIF, A   ; advance USTAT FIFO, BD now CPU owned

        ;; open coded jmpto
        movlw   UPPER(packet_handlers)
        movwf   PCLATU, A
        movlw   HIGH(packet_handlers)
        movwf   PCLATH, A
        banksel bdcopy
        rrncf   bdcopy+0, W, B  ; get the PIDs
        andlw   0x1E            ; filter out the needed bits
        addlw   LOW(packet_handlers)
        btfsc   STATUS, C, A
        incf    PCLATH, F, A
        btfsc   STATUS, C, A
        incf    PCLATU, F, A
        movwf   PCL, A
packet_handlers:
        return                  ; 0000 - special-reserved
        bra     usb_out_token   ; 0001 - token-out
        return                  ; 0010 - handshake-ack
        return                  ; 0011 - data-data0
        return                  ; 0100 - special-ping
        return                  ; 0101 - token-sof
        return                  ; 0110 - handshake-nyet
        return                  ; 0111 - data-data2
        return                  ; 1000 - special-split
        bra     usb_in_token    ; 1001 - token-in
        return                  ; 1010 - handshake-nack
        return                  ; 1011 - data-data1
        return                  ; 1100 - special-err/pre
        bra     usb_setup_token ; 1101 - token-setup
        return                  ; 1110 - handshake-stall
        return                  ; 1111 - data-mdata

        ;; disable the endpoints from 0 to 15
ep_disable_0_15:
        clrf    UEP0, A
        ;; disable the endpoints from 1 to 15
ep_disable_1_15:
        clrf    UEP1, A
        clrf    UEP2, A
        ;; disable the endpoints from 3 to 15
ep_disable_3_15:
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

        ;; memcpy() - copy W bytes from src to dst
        ;; @FSR0: src
        ;; @FSR1: dst
        ;; @W: byte count
        ;;
        ;; Copy W bytes from src to dst.
        ;;
        ;; Return: nothing
memcpy:
        movff   POSTINC0, POSTINC1
        addlw   -1
        bnz     memcpy
        return

        ;; ep_bdt_lookup() - load the BD addr into FSR1
        ;; @W: EP number [ | 0x80 ] (see below)
        ;;
        ;; Load the address of the BD for the EP in W
        ;; into FSR1.
        ;;
        ;; W = D7 00 00 00 D3 D2 D1 D0
        ;;      |           |  |  |  |
        ;;      |           +--+--+--+--- endpoint
        ;;      +------------------------ direction
        ;;
        ;; Return: BD address into FSR1
ep_bdt_lookup:
        andlw   0x8F            ; D7 00 00 00 D3 D2 D1 D0
        movwf   FSR1L, A
        rlncf   FSR1L, F, A     ; 00 00 00 D3 D2 D1 D0 D7
        rlncf   FSR1L, F, A     ; 00 00 D3 D2 D1 D0 D7 00
        rlncf   FSR1L, F, A     ; 00 D2 D2 D1 D0 D7 00 00
        movlw   HIGH(BD0OST)
        movwf   FSR1H, A
        return

        ;; usb_set_epaddr() - set the address of the endpoint
        ;; @W:    endpoint number (0x80 for input)
        ;; @FSR0: address of the endpoint
        ;;
        ;; This functions mangles FSR1.
        ;;
        ;; Return: nothing
usb_set_epaddr:
        call    ep_bdt_lookup
        bsf     FSR1L, 1, A     ; add 2 to FSR1 -> BDnnAL
        movf    FSR0L, W, A
        movwf   POSTINC1, A
        movf    FSR0H, W, A
        movwf   INDF1, A
        return

        ;; usb_get_epaddr() - get the address of the endpoint
        ;; @W:    endpoint number (0x80 for input)
        ;;
        ;; This functions mangles FSR0 and FSR1.
        ;;
        ;; Return: address of the USB buffer in FSR0
usb_get_epaddr:
        call    ep_bdt_lookup
        bsf     FSR1L, 1, A     ; add 2 to FSR1 -> BDnnAL
        movf    POSTINC1, W, A
        movwf   FSR0L, A
        movf    INDF1, W, A
        movwf   FSR0H, A
        return

        ;; ep_dir_valid() - check if the EP direction is correct
        ;; @W: EP number [ | 0x80 ] (see below)
        ;;
        ;; Check if the direction of the endpoint matches
        ;; the one programmed in the registers.
        ;;
        ;; The function mangles FSR1.
        ;;
        ;; W = D7 00 00 00 D3 D2 D1 D0
        ;;      |           |  |  |  |
        ;;      |           +--+--+--+--- endpoint
        ;;      +------------------------ direction
        ;;
        ;; Return: Carry flag set in case of mismatches
ep_dir_valid:
        lfsr    FSR1, UEP0      ; assume UEPn is in range 0x6A..0x79
        andlw   0x8F            ; D7 00 00 00 D3 D2 D1 D0
        addwf   FSR1L, A
        bcf     FSR1L, 7, A     ; FSR1 points to UEPn
        andlw   0x80            ; D7 00 00 00 00 00 00 00
        movlw   1<<EPOUTEN
        btfsc   STATUS, Z, A
        movlw   1<<EPINEN
        andwf   INDF1, W, A     ; filter out the direction of the UEPn
        bcf     STATUS, C, A
        btfsc   STATUS, Z, A    ; Z means error
        bsf     STATUS, C, A
        return

        ;; ep_bdt_prepare() - prepare the buffer descriptor
        ;; @W: size of the buffer
        ;; @custat: current endpoint in the 0x8F format
        ;;
        ;; Prepare the buffer descriptor for the next transaction.
        ;;
        ;; This function mangles FSR1.
        ;;
        ;; Returns: nothing
ep_bdt_prepare:
        banksel cnt
        movwf   cnt, B          ; save the buffer size to cnt
        movf    custat, W, B    ; take the current USTAT register
        andlw   0x3C            ; filter out the EP number and direction
        addlw   1               ; add 1 for BDnnCNT
        movwf   FSR1L, A        ; save into FSR1L
        movlw   HIGH(BD0OBC)    ; save the HIGH part of BDnnBC into FRS1H
        movwf   FSR1H, A        ; FSR1 points to BDnnCNT
        movf    cnt, W, B
        movwf   POSTDEC1, A     ; save the buffer size to cnt
        movf    INDF1, W, A     ; FSR1 now points to BDnnSTAT
        xorlw   1<<DTS          ; toggle DATA bit
        andlw   1<<DTS          ; filter it
        iorlw   1<<UOWN|1<<DTSEN
        movwf   INDF1, A        ; save it
        return

        ;; usb_change_state() - change the state of the device
        ;; @W: state of the device
        ;;
        ;; Return: nothing
usb_change_state:
        banksel uswstat
        movwf   uswstat, B
        goto    usb_status_event

        ;; ep0_send_ack
        ;;
        ;; send an empty acknowledge packet
ep0_send_ack:
        movlw   0
        ;; ep0_send_data
        ;;
        ;; send W bytes of data
ep0_send_data:
        banksel BD0IBC
        movwf   BD0IBC, B
        movlw   1<<UOWN|1<<DTS|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA1
        return

        ;; ep0_stall_error
        ;;
        ;; stall ep0 input and output
ep0_stall_error:
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
        ;; copy the received packet into bufdata
        banksel bdcopy
        movf    bdcopy+2, W, B  ; LSB of the address
        movwf   FSR0L, A
        movf    bdcopy+3, W, B  ; MSB of the address
        movwf   FSR0H, A        ; FSR0 points to the buffer for EP0
        lfsr    FSR1, bufdata   ; FSR1 points to the private bufdata

        movf    bdcopy+1, W, B  ; load the byte count
        sublw   MAXPACKETSIZE0
        movlw   MAXPACKETSIZE0
        btfss   STATUS, C, A    ; avoid overflows
        movf    bdcopy+1, W, B
        call    memcpy

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
        movf    bufdata+1, W, B
        movwf   devreq, B
        addlw   255 - 12
        addlw   (12 - 0) + 1
        btfss   STATUS, C, A
        bra     ep0_stall_error ; check if devreq is in range 0..12
        jmpto   devreq, B
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
        loff    Device
        bra     send_with_length

get_descriptor_configuration:
        movf    bufdata+2, W, B ; wValue
        bz      get_description_configuration_0
        bra     ep0_stall_error
get_description_configuration_0:
        loff    Configuration1
        movlw   (Configuration1End-Configuration1)
        bra     send_data

get_descriptor_hid:
        loff    HIDInterface
        call    send_with_length

get_descriptor_hidreport:
        loff    HIDReport
        movlw   (HIDReportEnd-HIDReport)
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
        loff    String0
        bra     send_with_length
get_descriptor_string1:
        loff    String1
        bra     send_with_length
get_descriptor_string2:
        loff    String2
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
        movlw   ADDRESSED_STATE
        subwf   uswstat, W, B   ; if (uswstat == ADDRESSED_STATE)
        btfss   STATUS, Z, A    ;   INDF0 = 0;
        movf    devconf, W, B   ; else
        movwf   INDF0, A        ;   INDF0 = devconf;
        movlw   1
        bra     ep0_send_data

set_configuration:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        ;; save the configuration number in devconf
        movf    bufdata+2, W, B ; wValue
        bz      unset_configuration
        addlw   -1
        bz      set_configuration_1
        bra     ep0_stall_error ; unknown configuration

unset_configuration:
        call    ep_disable_1_15 ; disable eps from 1 to 15
        movlw   ADDRESSED_STATE
        call    usb_change_state
        banksel devconf
        clrf    devconf, B      ; deconf = 0
        bra     ep0_send_ack

set_configuration_1:
        call    ep_disable_3_15 ; disable eps from 3 to 15

        ;; setup the endpoint 1 (IN, interrupt)
        ;; BD1IA[LH] are set by usb_set_epaddr()
        banksel BD1IBC
        movlw   IREPORT_SIZE    ; size of the packet
        movwf   BD1IBC, B
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD1IST, B       ; UOWN, DTS enabled
        movlw   1<<EPHSHK|1<<EPINEN
        movwf   UEP1, A         ; enable input, handshake

        ;; setup the endpoint 2 (OUT, interrupt)
        ;; BD2OA[LH] are set by usb_set_epaddr()
        banksel BD2OBC
        movlw   OREPORT_SIZE    ; size of the packet
        movwf   BD2OBC, B
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD2OST, B       ; buffer owned by the firmware, data toggle enable
        movlw   1<<EPHSHK|1<<EPOUTEN
        movwf   UEP2, A         ; enable output, handshake

        movlw   1
        banksel devconf
        movwf   devconf, B      ; devconf = 1
        movlw   CONFIGURED_STATE
        call    usb_change_state
        bra     ep0_send_ack

get_interface:
        call    check_request_acl ; ACL check
        btfsc   STATUS, C, A
        bra     ep0_stall_error

        movf    bufdata+4, W, B ; wIndex (interface number)
        bz      get_interface_0
        bra     ep0_stall_error
get_interface_0:
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

        movf    bufdata+4, W, B ; wIndex (interface number)
        bz      set_interface_0
        bra     ep0_stall_error
set_interface_0:
        bra     ep0_send_ack

get_status:
        call    check_request_acl ; ACL check
        bc      get_status_err

        movff   BD0IAH, FSR0H
        movff   BD0IAL, FSR0L   ; FSR0 == ep0 IN buffer

        banksel bufdata
        movf    bufdata+0, W, B ; bmRequestType
        andlw   0x1F
        bz      get_status_device
        addlw   -1
        bz      get_status_interface
        addlw   -1
        bz      get_status_endpoint
get_status_err:
        bra     ep0_stall_error
get_status_device:
        movf    devstat, W, B
        movwf   INDF0, A         ; byte[0] = devstat
        bra     get_status_send
get_status_interface:
        movlw   1                ; max number of interfaces
        subwf   bufdata+4, W, B  ; wIndex (interface number)
        bc      get_status_err   ; interface doesn't exist
        clrf    INDF0, A         ; byte[0] = 0
        bra     get_status_send
get_status_endpoint:
        movf    bufdata+4, W, B
        call    ep_dir_valid
        bc      get_status_err
        movf    bufdata+4, W, B ; wIndex (endpoint number | 0x80)
        call    ep_bdt_lookup
        clrf    INDF0, A        ; byte[0] = 0
        movf    INDF1, W, A     ; check the stall bit
        andlw   1<<BSTALL
        btfss   STATUS, Z, A
        incf    INDF0, F, A
get_status_send:
        clrf    PREINC0, A      ; byte[1] = 0
        movlw   0x02            ;
        bra     ep0_send_data   ; send 2 bytes

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
        movf    bufdata+4, W, B
        call    ep_dir_valid
        bc      xx_feature_err
        movf    bufdata+4, W, B
        call    ep_bdt_lookup   ; load BDT into FSR1
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
        movf    bufdata+1, W, B
        addlw   -0x0A           ; SET_IDLE
        bz      set_idle
        bra     ep0_stall_error
set_idle:
        bra     ep0_send_ack

        ;; process the vendor requests
vendor_requests:
        movf    bufdata+1, W, B ; bRequest
        bz      vendor_set
        bra     ep0_stall_error
vendor_set:
        movf    bufdata+2, W, B ; wValue
        ;; movwf   LATB, A
vendor_send:
        bra     ep0_send_ack

        ;; usb_in_token() - process an IN token
        ;;
        ;; process the IN (device -> host) token
        ;;
        ;; Return: nothing
usb_in_token:
        rlncf   custat, W, B
        andlw   0xF0
        bnz     usb_in_token_anyep
        movf    devreq, W, B    ; endpoint 0
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
        movlw   ADDRESSED_STATE ; UADDR != 0 -> the device is in addressed state
        bra     usb_change_state
usb_in_ep0_getdescriptor:
        bra     send_descriptor_packet
usb_in_token_anyep:             ; endpoints 1..15
        movwf   cnt, B
        swapf   cnt, W, B
        iorlw   0x80
        call    usb_tx_event
        movlw   IREPORT_SIZE
        bra     ep_bdt_prepare

        ;; usb_out_token() - process an OUT token
        ;;
        ;; process the OUT (host -> device) token
        ;;
        ;; Return: nothing
usb_out_token:
        rlncf   custat, W, B
        andlw   0xF8
        bnz     usb_out_token_anyep
        banksel BD0OBC          ; endpoint 0
        movlw   MAXPACKETSIZE0
        movwf   BD0OBC, B       ; MAXPACKETSIZE0 bytes
        movlw   1<<UOWN|1<<DTSEN
        movwf   BD0OST, B       ; UOWN, DATA0
        bra     ep0_send_ack
usb_out_token_anyep:
        movwf   cnt, B          ; endpoints 1..15
        swapf   cnt, W, B
        call    usb_rx_event
        movlw   OREPORT_SIZE
        bra     ep_bdt_prepare

        ;; check if the request is allowed for each state
check_request_acl:
        banksel bufdata
        movf    bufdata+1, W, B
        addlw   255 - 12
        addlw   (12 - 0) + 1
        bnc     check_request_err
        jmpto   bufdata+1, B
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
        movlw   ADDRESSED_STATE
        subwf   uswstat, W, B   ; set the C flag
        movf    bufdata+4, W, B ; if the request is for ep (C flag unaffected)
        andlw   0x0F            ; (C flag unaffected)
        bnz     check_request_err
        bra     check_request_toggle
check_allow_addressed:
        movlw   ADDRESSED_STATE
        bra     check_request_ok
check_allow_configured:
        movlw   CONFIGURED_STATE
check_request_ok:
        subwf   uswstat, W, B
check_request_toggle:
        btg     STATUS, C, A    ; C = (C==1)?0:1
        return

        ;; send_with_length() - send the data with encoded length
        ;;
        ;; Send the data where the first byte encodes the length
        ;;
        ;; Return: nothing
send_with_length:
        call    lookup_descriptor
        movwf   bleft, B
        bra     send_data_common

        ;; send_data() - send the data of length W
        ;; @W: length of the data
        ;;
        ;; Send the data of length W
        ;;
        ;; Return: nothing
send_data:
        movwf   bleft, B        ; save the length
        call    lookup_descriptor

send_data_common:
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
        movf    BD0IAH, W, B
        movwf   FSR0H, A
        movf    BD0IAL, W, B
        movwf   FSR0L, A        ; FSR0 = pointer to USB RAM

        ;; restore the lookup table
        call    lookup_descriptor
        banksel cnt
table_copy_loop:
        tblrd   *+
        movf    TABLAT, W, A
        movwf   POSTINC0, A

        incf    offset+0, F, B
        btfsc   STATUS, C, A
        incf    offset+1, F, B

        decf    cnt, F, B
        bnz     table_copy_loop

        ;; send the data
        banksel BD0IST
        movf    BD0IST, W, B
        xorlw   1<<DTS          ; toggle DATA bit
        andlw   1<<DTS          ; filter it
        iorlw   1<<UOWN|1<<DTSEN
        movwf   BD0IST, B       ; UOWN, DATA[01] bit
        return

        ;; lookup the descriptor from the offset in W
lookup_descriptor:
        banksel offset
        clrf    TBLPTRU, A
        movf    offset+1, W, B
        movwf   TBLPTRH, A
        movf    offset+0, W, B
        addlw   LOW(DescriptorBegin)
        movwf   TBLPTRL, A
        movlw   HIGH(DescriptorBegin)
        addwfc  TBLPTRH, F, A
        movlw   UPPER(DescriptorBegin)
        addwfc  TBLPTRU, F, A
        tblrd   *
        movf    TABLAT, W, A
        return

.usbtables      CODE_PACK

DescriptorBegin:
Device:
        db      0x12            ; bLength
        db      0x01            ; bDescriptorType = 1 (Device)
        db      0x10, 0x01      ; bcdUSB = USB 1.10
        db      0x00            ; USB-IF class
        db      0x00            ; USB-IF subclass
        db      0x00            ; USB-IF protocol
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
        db      0xC0            ; bmAttributes (selfPowered)
        db      50              ; bMaxPower (50 * 2mA = 100mA)

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
        db      0x05, 0x01       ; USAGE PAGE (Generic Desktop)
        db      0x09, 0x00       ; USAGE (Undefined)
        db      0xA1, 0x01       ; COLLECTION (Application)
        db      0x15, 0x00       ;   LOGICAL_MINIMUM (0)
        db      0x26, 0x00, 0xFF ;   LOGICAL_MAXIMUM (255)

        db      0x85, 0x01       ;   REPORT_ID (1)
        db      0x75, 0x08       ;   REPORT_SIZE (8)
        db      0x95, 0x07       ;   REPORT_COUNT (7) (IREPORT_SIZE-1)
        db      0x09, 0x00       ;   USAGE (Undefined)
        db      0x81, 0x82       ;   INPUT (Data, Var, Abs, Vol)

        db      0x85, 0x02       ;   REPORT_ID (2)
        db      0x75, 0x08       ;   REPORT_SIZE (8)
        db      0x95, 0x07       ;   REPORT_COUNT (7) (OREPORT_SIZE-1)
        db      0x09, 0x00       ;   USAGE (Undefined)
        db      0x91, 0x82       ;   OUTPUT (Data, Var, Abs, Vol)
        db      0xC0             ; END_COLLECTION
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
