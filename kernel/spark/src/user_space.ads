--  Espacios de direcciones de usuario, demostrados en SPARK.
--
--  Invariante inductiva (Invariant): la establece el estado inicial y la
--  conserva cada operación pública, así que vale en cualquier secuencia de
--  llamadas. El resto de lenguajes no puede romperla sin escribir en la memoria
--  privada de este paquete. De ella se deduce:
--
--    * Toda hoja de usuario lleva U, no lleva G y nunca es W+X.
--    * Toda hoja de un espacio apunta a un marco cuyo único dueño es ese espacio.
--    * Las tablas de un espacio solo apuntan a tablas del mismo espacio.
--    * Las entradas raíz del kernel son punteros a tablas, nunca hojas.
--    * Ningún marco de usuario puede ser una tabla de páginas.
--    * La página del dispositivo tiene como mucho un dueño y no es un marco.
--
--  Lemma_Isolation enuncia el teorema: dos espacios distintos nunca traducen a
--  un mismo marco. Walk modela el recorrido del hardware; que el procesador se
--  comporte así es una suposición.
--
--  No es reentrante: quien llama debe tener las interrupciones apagadas.

pragma Unevaluated_Use_Of_Old (Allow);

with Frame_Gate;
with Page_Tree; use Page_Tree;

package User_Space with
  SPARK_Mode,
  Abstract_State    => State,
  Initializes       => State,
  Initial_Condition => Invariant
is
   Max_Spaces : constant := 4;

   type Owner_Tag is range 0 .. Max_Spaces with Size => 8;
   subtype Space_Id is Owner_Tag range 1 .. Max_Spaces;
   No_Owner : constant Owner_Tag := 0;

   Page_Bytes : constant U64 := 2**12;

   --  Registros de la UART (FB_UART0_BASE). No pertenece al conjunto de marcos.
   Device_Ppn : constant U64 := 16#10000#;

   --  El usuario vive en las entradas raíz 4 .. 255. Las 0 .. 3 son del kernel.
   Kernel_Root_Slots : constant := 4;
   User_Base         : constant U64 := 2**32;
   User_Limit        : constant U64 := 2**38;

   type Kernel_Root_Index is range 0 .. Kernel_Root_Slots - 1;
   type Kernel_Root is array (Kernel_Root_Index) of U64 with Convention => C;

   Status_Ok        : constant U64 := 0;
   Status_Invalid   : constant U64 := 1;
   Status_No_Space  : constant U64 := 2;
   Status_Conflict  : constant U64 := 3;
   Status_No_Frames : constant U64 := 4;
   Status_Internal  : constant U64 := 5;

   Access_Read  : constant U64 := 1;
   Access_Write : constant U64 := 2;

   function In_User_Window (Va : U64) return Boolean is
     (Va >= User_Base and then Va < User_Limit);

   function Valid_Space (Space : U64) return Boolean is
     (Space >= 1 and then Space <= U64 (Max_Spaces));

   function Valid_Perm (Perm : U64) return Boolean is
     (Perm >= 1 and then Perm <= 3);

   function To_Permission (Perm : U64) return Permission is
     (case Perm is
        when 1      => Read_Only,
        when 2      => Read_Write,
        when others => Read_Execute)
   with Pre => Valid_Perm (Perm);

   --  W^X por construcción: Permission no permite pedir escritura y ejecución.
   function User_Leaf (Ppn : U64; Perm : Permission) return U64 is
     (Ppn * 1024 + Flag_V + Flag_R + Flag_U + Flag_A
      + (case Perm is
           when Read_Only    => 0,
           when Read_Write   => Flag_W + Flag_D,
           when Read_Execute => Flag_X))
   with Pre => Ppn < Max_Ppn;

   function Is_User_Leaf (E : U64) return Boolean is
     (E < 2**54
      and then (E and Flag_V) /= 0
      and then (E and Flag_R) /= 0
      and then (E and Flag_U) /= 0
      and then (E and Flag_G) = 0
      and then (E and (Flag_W or Flag_X)) /= (Flag_W or Flag_X));

   function Invariant return Boolean with
     Ghost,
     Global => (Input => State);

   --  La entrada final de una dirección, o 0 si el camino no existe.
   function Walk (S : Space_Id; Va : U64) return U64 with
     Global => (Input => State),
     Pre    => In_User_Window (Va);

   function Frame_Owner_Is (Ppn : U64; S : Space_Id) return Boolean with
     Ghost,
     Global => (Input => State);

   function No_Frames_Owned (S : Space_Id) return Boolean with
     Ghost,
     Global => (Input => State);

   --  Espacio que tiene el dispositivo, o No_Owner.
   function Device_Holder return Owner_Tag with
     Ghost,
     Global => (Input => State);

   --  Toda traducción existente es una hoja de usuario sobre un marco propio.
   procedure Lemma_Walk_Owned (S : Space_Id; Va : U64) with
     Ghost,
     Global => (Input => State),
     Pre    => Invariant and then In_User_Window (Va) and then Walk (S, Va) /= 0,
     Post   =>
       Is_User_Leaf (Walk (S, Va))
       and then Frame_Owner_Is (Ppn_Of (Walk (S, Va)), S);

   --  Teorema de aislamiento entre espacios de direcciones.
   procedure Lemma_Isolation (A, B : Space_Id; Va_A, Va_B : U64) with
     Ghost,
     Global => (Input => State),
     Pre    =>
       Invariant
       and then A /= B
       and then In_User_Window (Va_A)
       and then In_User_Window (Va_B)
       and then Walk (A, Va_A) /= 0
       and then Walk (B, Va_B) /= 0,
     Post   => Ppn_Of (Walk (A, Va_A)) /= Ppn_Of (Walk (B, Va_B));

   --  Solo puede completarse una vez. La reserva de tablas debe estar por
   --  debajo de los marcos, y las entradas del kernel deben ser punteros.
   function Init
     (Pool_Address : U64;
      First_Frame  : U64;
      Count        : U64;
      Entries      : Kernel_Root) return U64
   with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant and then (Init'Result = Status_Ok or else Init'Result = Status_Invalid),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_init";

   --  Devuelve un espacio nuevo, o 0 si no quedan.
   function Create return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          => Invariant and then Create'Result <= U64 (Max_Spaces),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_create";

   --  Número de página física de la raíz, o 0 si el espacio no existe.
   function Root_Ppn (Space : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Export,
     Convention    => C,
     External_Name => "fb_uspace_root";

   --  Reserva un marco y lo mapea en Va. Devuelve su dirección física, o un
   --  código de estado (siempre menor que una página) si no pudo hacerlo.
   function Map_New (Space, Va, Perm : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => (State, Frame_Gate.State)),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Map_New'Result >= Page_Bytes
          then Valid_Space (Space)
            and then In_User_Window (Va)
            and then Valid_Perm (Perm)
            and then Map_New'Result mod Page_Bytes = 0
            and then Map_New'Result / Page_Bytes < Max_Ppn
            and then Frame_Owner_Is (Map_New'Result / Page_Bytes, Space_Id (Space))
            and then Walk (Space_Id (Space), Va)
                       = User_Leaf (Map_New'Result / Page_Bytes, To_Permission (Perm))),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_map";

   --  Mapea los registros del dispositivo en Va, sin ejecución. Solo puede
   --  tenerlos un espacio a la vez: quien llega después recibe un error.
   function Map_Device (Space, Va : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then (if Device_Holder'Old /= No_Owner then Map_Device'Result /= Status_Ok)
       and then
         (if Map_Device'Result = Status_Ok
          then Valid_Space (Space)
            and then In_User_Window (Va)
            and then Va mod Page_Bytes = 0
            and then Device_Holder = Space_Id (Space)
            and then Walk (Space_Id (Space), Va) = User_Leaf (Device_Ppn, Read_Write)),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_map_device";

   --  Dirección física de la página de Va, o 0 si ese espacio no la tiene
   --  accesible en ese modo. El kernel solo debe tocar memoria de usuario así.
   function Translate (Space, Va, Mode : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       (if Translate'Result /= 0
        then Valid_Space (Space)
          and then In_User_Window (Va)
          and then (Mode = Access_Read or else Mode = Access_Write)
          and then Translate'Result mod Page_Bytes = 0
          and then Translate'Result / Page_Bytes /= Device_Ppn
          and then Translate'Result / Page_Bytes = Ppn_Of (Walk (Space_Id (Space), Va))
          and then Frame_Owner_Is (Translate'Result / Page_Bytes, Space_Id (Space))
          and then
            (if Mode = Access_Write
             then (Walk (Space_Id (Space), Va) and Flag_W) /= 0)),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_translate";

   --  Libera todos los marcos del espacio y lo deja vacío. Quien llama no debe
   --  estar usando estas tablas.
   function Destroy (Space : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => (State, Frame_Gate.State)),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Destroy'Result = Status_Ok
          then Valid_Space (Space)
            and then No_Frames_Owned (Space_Id (Space))
            and then Device_Holder /= Space_Id (Space)),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_destroy";

end User_Space;
