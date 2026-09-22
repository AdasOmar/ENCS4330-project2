;==============================================================================
;  Project : Simple Medicine Reminder System
;  Course  : ENCS4330 Real-Time Applications & Embedded Systems
;  MCU     : PIC16F877A @ 4 MHz (XT crystal, 1 us instruction cycle)
;  File    : med_reminder_base.asm
;  Content : Configuration, variables, definitions, initialization and
;            basic time/reminder routines (Topic 1 exercises C1-C7)
;==============================================================================

        list        p=16f877a
        #include    <p16f877a.inc>

        __CONFIG    _XT_OSC & _WDT_OFF & _PWRTE_ON & _LVP_OFF & _CP_OFF

; Suppress "Register in operand not in bank 0" (bank switching is done
; explicitly with BANKSEL in every routine that uses bank 1 registers).
        errorlevel  -302

;==============================================================================
;  VARIABLES
;==============================================================================

; ---- Bank 0 general purpose RAM ----------------------------------------------
        cblock  0x20
        SEC                     ; Current time: seconds (0-59)
        MIN                     ; Current time: minutes (0-59)
        HOUR                    ; Current time: hours   (0-23)
        REM_H1                  ; Reminder hours array   (keep consecutive)
        REM_H2
        REM_H3
        REM_M1                  ; Reminder minutes array (keep consecutive,
        REM_M2                  ; directly after the hours array)
        REM_M3
        HOUR_IN                 ; Keypad input buffer: hours
        MIN_IN                  ; Keypad input buffer: minutes
        MED_IDX                 ; Medicine index (0, 1 or 2)
        COUNT                   ; General purpose loop counter
        TEMP                    ; General purpose temporary storage
        endc

; ---- Common RAM (0x70-0x7F, accessible from every bank) ----------------------
        cblock  0x70
        W_TEMP                  ; ISR context save: W
        STATUS_TEMP             ; ISR context save: STATUS
        FLAGS                   ; Shared status flags (main program and ISR)
        endc

;==============================================================================
;  DEFINITIONS
;==============================================================================

; ---- FLAGS register bit numbers ----------------------------------------------
ERR_BIT         equ     0       ; Invalid time entered
MATCH_BIT       equ     1       ; Current time matches a reminder
TICK_BIT        equ     2       ; One-second tick from the timer ISR

; ---- FLAGS bit aliases (usage: bsf ERR / btfsc MATCH) ------------------------
#define ERR         FLAGS, ERR_BIT
#define MATCH       FLAGS, MATCH_BIT
#define TICK        FLAGS, TICK_BIT

; ---- STATUS flag aliases (usage: btfsc CARRY / btfss ZERO) -------------------
#define CARRY       STATUS, C
#define ZERO        STATUS, Z

; ---- I/O pin aliases (usage: bsf LED1 / btfss ACK_BTN) -----------------------
; PORTB: RB0-RB3 keypad columns (in), RB4-RB7 keypad rows (out)
; PORTC: outputs and acknowledge button
#define LED1        PORTC, 0
#define LED2        PORTC, 1
#define LED3        PORTC, 2
#define BUZZER      PORTC, 3
#define ACK_BTN     PORTC, 4
; PORTD: LCD in 4-bit mode (data on RD4-RD7)
#define LCD_RS      PORTD, 0
#define LCD_E       PORTD, 1

; ---- Constants ---------------------------------------------------------------
MAX_HOUR        equ     d'24'   ; First invalid hour value
MAX_MIN         equ     d'60'   ; First invalid minute value
MAX_SEC         equ     d'60'   ; Seconds rollover value

;==============================================================================
;  RESET AND INTERRUPT VECTORS
;==============================================================================
        org     0x0000
        goto    Main

        org     0x0004
ISR
        retfie                  ; Placeholder: timer ISR added in Topic 7

;==============================================================================
;  MAIN PROGRAM
;==============================================================================
Main
        call    InitPorts
        call    InitVars
MainLoop
        goto    MainLoop        ; Placeholder: main loop logic added later

;==============================================================================
;  InitPorts
;  Configures port directions, output start values, PORTB pull-ups and
;  digital mode for PORTA/PORTE.
;  Input  : none
;  Output : none
;  Changes: W, bank select (returns in bank 0)
;==============================================================================
InitPorts
        banksel PORTB           ; Bank 0: set output values first
        movlw   0xF0
        movwf   PORTB           ; Keypad rows idle high
        clrf    PORTC           ; LEDs and buzzer OFF
        clrf    PORTD           ; LCD lines low

        banksel TRISB           ; Bank 1: set directions
        movlw   b'00001111'
        movwf   TRISB           ; RB0-RB3 inputs, RB4-RB7 outputs
        movlw   b'00010000'
        movwf   TRISC           ; RC4 input, all others outputs
        clrf    TRISD           ; All PORTD pins outputs
        bcf     OPTION_REG, NOT_RBPU    ; Enable PORTB pull-ups (active low)
        movlw   0x06
        movwf   ADCON1          ; PORTA and PORTE digital I/O

        banksel PORTB           ; Return in bank 0
        return

;==============================================================================
;  InitVars
;  Clears the clock, all reminder times and all flags. RAM contents are
;  undefined at power-up, so this must run before the timer is started.
;  Input  : none
;  Output : none
;  Changes: W, FSR
;==============================================================================
InitVars
        clrf    SEC
        clrf    MIN
        clrf    HOUR
        call    ClearReminders
        clrf    FLAGS
        return

;==============================================================================
;  ValidateTime
;  Checks the time held in the input buffer.
;  Input  : HOUR_IN, MIN_IN (not modified)
;  Output : ERR = 1 if HOUR_IN >= 24 or MIN_IN >= 60, otherwise ERR = 0
;  Changes: W, STATUS
;==============================================================================
ValidateTime
        bcf     ERR             ; Assume the time is valid
        movlw   MAX_HOUR
        subwf   HOUR_IN, W      ; W = HOUR_IN - 24
        btfsc   CARRY           ; C = 0: HOUR_IN < 24, skip
        bsf     ERR             ; C = 1: HOUR_IN >= 24, invalid
        btfsc   CARRY           ; BSF does not affect C
        return                  ; Hour invalid: exit with ERR = 1
        movlw   MAX_MIN
        subwf   MIN_IN, W       ; W = MIN_IN - 60
        btfsc   CARRY           ; C = 0: MIN_IN < 60, skip
        bsf     ERR             ; C = 1: MIN_IN >= 60, invalid
        return

;==============================================================================
;  ClearReminders
;  Clears the six reminder bytes REM_H1 to REM_M3 using indirect addressing.
;  Requires REM_H1 to REM_M3 to be at consecutive addresses.
;  Input  : none
;  Output : REM_H1-REM_H3 and REM_M1-REM_M3 = 0
;  Changes: W, FSR, STATUS
;==============================================================================
ClearReminders
        movlw   REM_H1          ; W = address of the first reminder byte
        movwf   FSR
CR_Loop
        clrf    INDF            ; Clear the byte pointed to by FSR
        incf    FSR, F          ; Point to the next byte
        movf    FSR, W
        xorlw   (REM_M3 + 1)    ; Z = 1 when FSR passes the last byte
        btfss   ZERO
        goto    CR_Loop
        return

;==============================================================================
;  IncSecond
;  Increments the seconds counter with rollover from 59 to 0.
;  Input  : SEC (must be initialized, see InitVars)
;  Output : SEC = (SEC + 1) mod 60
;  Changes: W, STATUS
;==============================================================================
IncSecond
        incf    SEC, F          ; SEC = SEC + 1
        movlw   MAX_SEC
        xorwf   SEC, W          ; Z = 1 when SEC = 60
        btfsc   ZERO
        clrf    SEC             ; Rollover: 60 -> 0
        return

;==============================================================================
;  CheckRem1
;  Compares the current time with the reminder time of medicine 1.
;  Input  : HOUR, MIN, REM_H1, REM_M1 (not modified)
;  Output : MATCH = 1 if HOUR = REM_H1 and MIN = REM_M1, otherwise MATCH = 0
;  Changes: W, STATUS
;==============================================================================
CheckRem1
        bcf     MATCH           ; Assume no match
        movf    HOUR, W
        xorwf   REM_H1, W       ; Z = 1 when HOUR = REM_H1
        btfss   ZERO
        return                  ; Hours differ: no match
        movf    MIN, W
        xorwf   REM_M1, W       ; Z = 1 when MIN = REM_M1
        btfss   ZERO
        return                  ; Minutes differ: no match
        bsf     MATCH           ; Hours and minutes both equal
        return

;==============================================================================
;  GetRemHour
;  Returns the reminder hour of the selected medicine.
;  Input  : MED_IDX (0, 1 or 2)
;  Output : W = REM_H1[MED_IDX]
;  Changes: W, FSR, STATUS
;==============================================================================
GetRemHour
        movlw   REM_H1          ; W = base address of the hours array
        addwf   MED_IDX, W      ; W = base address + index
        movwf   FSR
        movf    INDF, W         ; W = selected reminder hour
        return

;==============================================================================
        end
