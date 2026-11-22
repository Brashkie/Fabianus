--  SPDX-License-Identifier: GPL-3.0-or-later
--  Espacios de direcciones de usuario, demostrados en SPARK.
--
--  Invariante inductiva (Invariant): la establece el estado inicial y la
--  conserva cada operación pública, así que vale en cualquier secuencia de
--  llamadas. El resto de lenguajes no puede romperla sin escribir en la memoria
--  privada de este paquete. De ella se deduce:
--
--    * Toda hoja de usuario lleva U, no lleva G y nunca es W+X.
--    * Toda hoja de un espacio apunta a un marco suyo o a un marco de una
--      región compartida a la que ese espacio está unido.
--    * Cada marco tiene a lo sumo un dueño: un espacio o una región.
--    * Las tablas de un espacio solo apuntan a tablas del mismo espacio.
--    * Las entradas raíz del kernel son punteros a tablas, nunca hojas.
--    * Ningún marco de usuario puede ser una tabla de páginas.
--    * La página del dispositivo tiene como mucho un dueño y no es un marco.
--
--  Lemma_Isolation enuncia el teorema: dos espacios distintos solo traducen a
--  un mismo marco si es de una región compartida unida a los dos. Un marco
--  propio de un espacio nunca es accesible desde otro (Lemma_Private). Walk
--  modela el recorrido del hardware; que el procesador se comporte así es una
--  suposición.
--
--  Regiones compartidas. Una región es una lista de marcos cuyo dueño es la
--  región, no un espacio. Un espacio solo puede mapear sus páginas después de
--  unirse a ella (Region_Attach), y solo deja de estar unido al destruirse.
--  Una región solo se libera cuando ningún espacio está unido. Quién puede
--  unirse lo decide el kernel con una capability (Cap_Core).
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
   Max_Spaces       : constant := 4;
   Max_Regions      : constant := 4;
   Max_Region_Pages : constant := 16;

   --  Dueño de un marco: nadie, un espacio (1 .. 4) o una región (5 .. 8: la
   --  región R tiene el dueño Max_Spaces + R).
   type Owner_Tag is range 0 .. Max_Spaces + Max_Regions with Size => 8;
   subtype Space_Id is Owner_Tag range 1 .. Max_Spaces;
   subtype Holder_Id is Owner_Tag range 1 .. Owner_Tag'Last;
   subtype Region_Tag is Owner_Tag range Max_Spaces + 1 .. Owner_Tag'Last;
   No_Owner : constant Owner_Tag := 0;

   Page_Bytes : constant U64 := 2**12;

   --  Páginas de registros de dispositivos que se pueden ceder, cada una a un
   --  solo espacio: 0, la UART (FB_UART0_BASE); 1, el disco virtio
   --  (FB_VIRTIO0_BASE). No pertenecen al conjunto de marcos.
   Max_Devices : constant := 2;
   type Device_Id is range 0 .. Max_Devices - 1;
   type Device_Map is array (Device_Id) of Owner_Tag;

   function Device_Ppn (D : Device_Id) return U64 is
     (if D = 0 then 16#10000# else 16#10001#);

   --  Definida con la tabla de arriba: no puede quedarse atrás si se añade un
   --  dispositivo (una mutación de una copia aparte sobrevivía).
   function Is_Device_Ppn (Ppn : U64) return Boolean is
     (for some D in Device_Id => Ppn = Device_Ppn (D));

   function Valid_Device (Device : U64) return Boolean is
     (Device < U64 (Max_Devices));

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

   function Valid_Region (Region : U64) return Boolean is
     (Region >= 1 and then Region <= U64 (Max_Regions));

   function Tag_Of (Region : U64) return Region_Tag is
     (Region_Tag (U64 (Max_Spaces) + Region))
   with Pre => Valid_Region (Region);

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

   --  Espacio que tiene cada dispositivo, o No_Owner.
   function Device_Holders return Device_Map with
     Ghost,
     Global => (Input => State);

   --  S está unido a la región R.
   function Attached_To (R : Region_Tag; S : Space_Id) return Boolean with
     Ghost,
     Global => (Input => State);

   --  El marco es de una región unida a A y a B.
   function Shared_By (Ppn : U64; A, B : Space_Id) return Boolean with
     Ghost,
     Global => (Input => State);

   --  El marco es de S y solo de S (no es de ninguna región ni el dispositivo).
   function Private_To (Ppn : U64; S : Space_Id) return Boolean with
     Ghost,
     Global => (Input => State);

   --  Número de páginas de la región R (0 si no existe).
   function Pages_Of (R : Region_Tag) return U64 with
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

   --  Teorema de aislamiento entre espacios de direcciones: dos espacios
   --  distintos solo llegan al mismo marco si es de una región unida a ambos.
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
     Post   =>
       Ppn_Of (Walk (A, Va_A)) /= Ppn_Of (Walk (B, Va_B))
       or else Shared_By (Ppn_Of (Walk (A, Va_A)), A, B);

   --  Un marco propio de A no lo traduce ningún otro espacio.
   procedure Lemma_Private (A, B : Space_Id; Va_A, Va_B : U64) with
     Ghost,
     Global => (Input => State),
     Pre    =>
       Invariant
       and then A /= B
       and then In_User_Window (Va_A)
       and then In_User_Window (Va_B)
       and then Walk (A, Va_A) /= 0
       and then Walk (B, Va_B) /= 0
       and then Private_To (Ppn_Of (Walk (A, Va_A)), A),
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

   --  Mapea los registros del dispositivo Device en Va, sin ejecución. Solo
   --  puede tenerlos un espacio a la vez: quien llega después recibe un error.
   function Map_Device (Space, Device, Va : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Valid_Device (Device) and then Device_Holders'Old (Device_Id (Device)) /= No_Owner
          then Map_Device'Result /= Status_Ok)
       and then
         (if Map_Device'Result = Status_Ok
          then Valid_Space (Space)
            and then Valid_Device (Device)
            and then In_User_Window (Va)
            and then Va mod Page_Bytes = 0
            and then Device_Holders (Device_Id (Device)) = Space_Id (Space)
            and then
              Walk (Space_Id (Space), Va) = User_Leaf (Device_Ppn (Device_Id (Device)), Read_Write)),
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
          and then not Is_Device_Ppn (Translate'Result / Page_Bytes)
          and then Translate'Result / Page_Bytes = Ppn_Of (Walk (Space_Id (Space), Va))
          and then Frame_Owner_Is (Translate'Result / Page_Bytes, Space_Id (Space))
          and then
            (if Mode = Access_Write
             then (Walk (Space_Id (Space), Va) and Flag_W) /= 0)),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_translate";

   --  Crea una región de Pages marcos (1 .. Max_Region_Pages), sin ningún
   --  espacio unido. Devuelve su número (1 .. Max_Regions) o 0 si no quedan
   --  regiones o marcos; entonces no se queda con nada. Quien llama debe
   --  poner las páginas a cero (Region_Frame) antes de que nadie las vea.
   function Region_Create (Pages : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => (State, Frame_Gate.State)),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then Region_Create'Result <= U64 (Max_Regions)
       and then
         (if Region_Create'Result /= 0
          then Pages in 1 .. U64 (Max_Region_Pages)
            and then Pages_Of (Tag_Of (Region_Create'Result)) = Pages
            and then
              (for all S in Space_Id => not Attached_To (Tag_Of (Region_Create'Result), S))),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_create";

   --  Dirección física de la página Page (0 .. Pages - 1) de la región, o 0.
   function Region_Frame (Region, Page : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       (if Region_Frame'Result /= 0
        then Valid_Region (Region)
          and then Page < Pages_Of (Tag_Of (Region))
          and then Region_Frame'Result mod Page_Bytes = 0),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_frame";

   --  Une el espacio a la región: desde entonces puede mapear sus páginas.
   --  Quien llama comprueba antes la capability.
   function Region_Attach (Space, Region : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Region_Attach'Result = Status_Ok
          then Valid_Space (Space)
            and then Valid_Region (Region)
            and then Pages_Of (Tag_Of (Region)) > 0
            and then Attached_To (Tag_Of (Region), Space_Id (Space))),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_attach";

   --  Mapea la página Page de la región en Va, solo lectura o lectura y
   --  escritura (nunca ejecución). Solo si el espacio está unido a la región.
   function Region_Map (Space, Region, Page, Va, Writable : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => State),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Region_Map'Result = Status_Ok
          then Valid_Space (Space)
            and then Valid_Region (Region)
            and then In_User_Window (Va)
            and then Attached_To (Tag_Of (Region), Space_Id (Space))
            and then Page < Pages_Of (Tag_Of (Region))
            and then Walk (Space_Id (Space), Va) /= 0
            and then Is_User_Leaf (Walk (Space_Id (Space), Va))
            and then (Walk (Space_Id (Space), Va) and Flag_X) = 0
            and then ((Walk (Space_Id (Space), Va) and Flag_W) /= 0) = (Writable /= 0)),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_map";

   --  Dirección física de la página Page de la región, solo si Space está
   --  unido a ella (si no, 0): lo que un driver necesita para programar DMA
   --  sobre la memoria que comparte, y nada más.
   function Region_Frame_For (Space, Region, Page : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       (if Region_Frame_For'Result /= 0
        then Valid_Space (Space)
          and then Valid_Region (Region)
          and then Attached_To (Tag_Of (Region), Space_Id (Space))
          and then Page < Pages_Of (Tag_Of (Region))
          and then Region_Frame_For'Result mod Page_Bytes = 0
          and then Shared_By (Region_Frame_For'Result / Page_Bytes, Space_Id (Space), Space_Id (Space))),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_frame_for";

   --  1 si algún espacio está unido a la región, 0 si no (o si no existe).
   function Region_In_Use (Region : U64) return U64 with
     Global        => (Input => State),
     Pre           => Invariant,
     Post          =>
       (if Valid_Region (Region)
        then (Region_In_Use'Result = 1)
             = (for some S in Space_Id => Attached_To (Tag_Of (Region), S))),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_in_use";

   --  Libera los marcos de una región a la que no está unido ningún espacio.
   --  Con algún espacio unido devuelve Status_Conflict sin tocar nada.
   function Region_Free (Region : U64) return U64 with
     Side_Effects,
     Global        => (In_Out => (State, Frame_Gate.State)),
     Pre           => Invariant,
     Post          =>
       Invariant
       and then
         (if Region_Free'Result = Status_Ok
          then Valid_Region (Region)
            and then Pages_Of (Tag_Of (Region)) = 0),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_region_free";

   --  Libera todos los marcos del espacio y lo deja vacío, sin unirlo ya a
   --  ninguna región. Quien llama no debe estar usando estas tablas.
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
            and then (for all D in Device_Id => Device_Holders (D) /= Space_Id (Space))
            and then (for all R in Region_Tag => not Attached_To (R, Space_Id (Space)))),
     Export,
     Convention    => C,
     External_Name => "fb_uspace_destroy";

end User_Space;
