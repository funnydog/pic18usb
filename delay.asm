        include "config.inc"
        global _udelay, _udc

.ddata  udata_acs

_udc    res     1               ; byte for high side

.delay  code

        nop                     ; entry point for delay%3 == 2
        nop                     ; entry point for delay%3 == 1
_udelay addlw   -3              ; subtract 3 cycle loop time     1CLK
        bc      _udelay         ;                                2CLK
_udhi   addlw   -3              ; subtract 3 cycle loop time     1CLK
        incfsz  _udc, F, A      ; delay done? yes, skip, else    2CLK
        bra     _udelay         ; loop again                     2CLK
        return                  ;                                2CLK

        end
