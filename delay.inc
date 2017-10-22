        radix   dec
        extern  _udelay, _udc

        ;; delay_cycles 16..65547
delaycy macro  delay                    ; parameter range 16..65547
        movlw  (~(high(delay-12))&0xFF) ; 1CLK
        movwf   _udc, A                 ; 1CLK
        movlw   low(delay-12)           ; 1CLK
        rcall   _udelay-(((delay)%3)*2) ; 2CLK
        endm

