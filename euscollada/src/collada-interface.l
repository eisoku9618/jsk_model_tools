(load "xml.l")
(load "eusmodel-description.l")

(setq *collada-print-customize-symbols* '(collada |profile_COMMON|))

(defun eusmodel-description->collada (name description &key (scale 0.001))
  "convert eusmodel-descrption to collada sxml"
  (warn "start converting to collada sxml~%")
  `(collada
    (@ (version "1.5.0")
       (xmlns "http://www.collada.org/2008/03/COLLADASchema")
       ;; (xmlns:xsi "http://www.w3.org/2001/XMLSchema-instance")
       ;; (xmlns:math "http://www.w3.org/1998/Math/MathML")
       ;; (xsi:schemaLocation "http://www.collada.org/2008/03/COLLADASchema http://www.khronos.org/files/collada_schema_1_5")
       )
    (asset
     (contributor (authoring_tool 
                    "Eus2Collada"))
     (unit (@ (meter ,scale)
              (name "millimeter")))
     (up_axis "Z_UP"))
    ,(eusmodel-description->collada-library-visual-scenes description)
    ,(eusmodel-description->collada-library-joints description)
    ,(links-description->collada-library-effects (eusmodel-link-description description))
    ,(links-description->collada-library-materials (eusmodel-link-description description))
    ,(eusmodel-description->collada-library-kinematics-models name description)
    ,(eusmodel-description->collada-library-kinematics-scenes name description)
    ,(eusmodel-description->collada-library-geometries description)
    ,(eusmodel-description->collada-library-articulated-systems description name)
    ;; default scene...
    ,(eusmodel-description->collada-scene description)))

(defun setup-collada-filesystem (obj-name base-dir)
  (if (not (eq (probe-file base-dir) :directory))
      (error "~A must be a directory" base-dir)
    (progn
      (unix::mkdir (format nil "~A/collada" base-dir)))))

(defun range2 (n)
  (if (= n 0)
      '(0)
    (append (range2 (1- n)) (list n))))

(defun eus2collada (obj root-dir
                        &key
                        (scale 0.001)
                        (file-suffix ".dae"))
  (let ((name (send obj :name))
        (full-root-dir (ros::resolve-ros-path root-dir)))
    (unless name
      (error "You need to specify name"))
    (let ((descrpition (eusmodel-description obj)))
      (let ((sxml (eusmodel-description->collada
                   name descrpition :scale scale)))
        (setup-collada-filesystem name full-root-dir) ;mkdir for collada
        (let ((xml-file (format nil "~Acollada/~A.dae" full-root-dir name))
              (xml (sxml->xml sxml)))
          (with-open-file (f xml-file :direction :output)
            (format f "<?xml version=\"1.0\"?>~%")
            (xml-output-to-string-stream f xml)
            nil))))))


(defun collada-node-id (link-descrption)
  (format nil "~A.node" (cdr (assoc :name link-descrption))))

(defun collada-node-name (link-descrption)
  (format nil "~A_node" (cdr (assoc :name link-descrption))))

(defun links-description->collada-library-materials (links-desc)
  `(library_materials
    (@ (id "libmat"))
    ,@(mapcar #'link-description->collada-materials links-desc)))

(defun link-description->collada-materials (link-desc)
  (let* ((meshes (cdr (assoc :mesh link-desc)))
         (id-base (format nil "~A.geometry" (cdr (assoc :name link-desc))))
         (effect-base (format nil "~A.effect" (cdr (assoc :name link-desc))))
         (ids (range2 (length meshes))))
    (mapcar #'(lambda (i)
                (mesh-description->collada-material
                 (format nil "~A.~A.material" id-base i)
                 (format nil "~A.~A" effect-base i)))
            ids)))

(defun mesh-description->collada-material (mat effect)
  `(material
    (@ (id ,mat))
    (instance_effect
     (@ (url ,(format nil "#~A" effect))))))

(defun links-description->collada-library-effects (links-desc)
  `(library_effects
    (@ (id "libeffect"))
    ,@(mapcar #'link-description->collada-effects links-desc)))

(defun link-description->collada-effects (link-desc)
  (let* ((meshes (cdr (assoc :mesh link-desc)))
         (id-base (format nil "~A.effect" (cdr (assoc :name link-desc))))
         (ids (range2 (length meshes))))
    (mapcar #'(lambda (x i)
                (mesh-description->collada-effect
                 x (format nil "~A.~A" id-base i)))
            meshes ids)))

(defun mesh-description->collada-effect (mesh id)
  `(effect
    (@ (id ,id))
    (|profile_COMMON|
     (technique
      (@ (sid "common"))
      (phong
       (ambient
        (color
         ,(format nil "~A ~A ~A 1.0"
                  (elt (get mesh :face-color) 0)
                  (elt (get mesh :face-color) 1)
                  (elt (get mesh :face-color) 2))))
       (diffuse
        (color
         ,(format nil "~A ~A ~A 1.0"
                  (elt (get mesh :face-color) 0)
                  (elt (get mesh :face-color) 1)
                  (elt (get mesh :face-color) 2)))))))))

(defun matrix->collada-string (mat)
  (let ((dims (array-dimensions mat))
        (ss (make-string-output-stream)))
    (dotimes (i (car dims))
      (dotimes (j (cadr dims))
        (format ss "~A " (aref mat i j))))
    (format ss "~%")
    (get-output-stream-string ss)))

(defun find-parent-liks-from-link-description (target-link desc)
  (let ((j (find-joint-from-link-description target-link (eusmodel-link-description desc))))
    (if (null j)
        nil
      (let* ((parent-link-name (cdr (assoc :parent j)))
             (parent-link (find-link-from-links-description
                           parent-link-name ((eusmodel-link-description desc)))))
        (append (find-parent-liks-from-link-description parent-link desc)
                (list parent-link))))))

(defun eusmodel-description->collada-node-transformations (target-link desc)
  (let ((parent-links
         (append (find-parent-liks-from-link-description target-link desc)
                 (list target-link))))
    (remove-if #'null
               (mapcar #'(lambda (l)
                           (let ((j (find-joint-from-link-description
                                     l (eusmodel-joint-description desc))))
                             (if j
                                 `((rotate
                                    (@ (sid
                                        ,(format nil "~A_axis0" (cdr (assoc :name j)))))
                                    "1 0 0 0")))))
                       parent-links))))

(defun eusmodel-description->collada-node (target-link desc)
  (let* ((joint-descriptions (eusmodel-joint-description desc))
         (link-descriptions (eusmodel-link-description desc))
         (j (find-joint-from-link-description target-link (eusmodel-joint-description desc)))
         (meshes (cdr (assoc :mesh target-link)))
         (origin (cdr (assoc :origin target-link))))
  `(node
    (@ (id ,(collada-node-id target-link))
       (name ,(collada-node-name target-link)))
    ,@(eusmodel-description->collada-node-transformations target-link desc)
    ,@(mapcar
       #'(lambda (i)
           `(instance_geometry
             (@ (url
                 ,(format nil "#~A.~A"
                          (collada-geometry-id-base target-link)
                          i)))
             (bind_material
              (technique_common
               (instance_material
                (@ (symbol ,(format nil "~A.~A.material"
                                    (collada-geometry-id-base target-link) i))
                   (target ,(format nil "#~A.~A.material"
                                    (collada-geometry-id-base target-link) i))))))))
       (enum-integer-list (length meshes))))))

(defun eusmodel-description->collada-library-visual-scenes (desc)
  `(library_visual_scenes
    (@ (id "libvisualscene"))
    (visual_scene
     (@ (id "libvisualscenes.scene"))
     (node
      (@ (id "visual_root")
         (name "VisualRoot"))
      (node
       (@ (id "root_node")
          (name "RootNode"))
       ,@(mapcar #'(lambda (l)
                     (eusmodel-description->collada-node l desc))
                 (eusmodel-link-description desc)))))))

(defun mesh-description->instance-material (s)
  `(instance_material
    (@ (symbol ,s)
       (target ,(format nil "#~A" s)))))

(defun link-description->collada-bind-material (link)
  (let* ((meshes (cdr (assoc :mesh link)))
         (name (cdr (assoc :name link)))
         (ids (enum-integer-list (length meshes))))
    ;; material
    `(bind_material
      (technique_common
       ,@(mapcar #'(lambda (n)
                     (mesh-description->instance-material
                      (format nil "~A.geometry.~A.material" name n)))
                 ids)))))

(defun eusmodel-description->collada-library-kinematics-scenes (name desc)
  `(library_kinematics_scenes
    (@ (id "libkinscenes"))
    (kinematics_scene
     (@ (id "libkinscenes.kinScene"))
     (instance_articulated_system
      (@ (url "#kinsystem_motion")
         (sid "inst_kinsystem"))
      (newparam
       (@ (sid "libkinscenes.kinScene_libkinscenes.kinScene_inst_kinmodel"))
       "<SIDREF>kinsystem_motion/kinsystem_motion.kinsystem_inst</SIDREF>")
      ;; joint axis
      ,@(mapcar #'(lambda (j)
                    (let ((joint-name (cdr (assoc :name j))))
                      `(newparam
                        (@ (sid ,(format nil "libkinscenes.kinScene_libkinscenes.kinScene_inst_kinmodel.~A_axis0" joint-name)))
                        ,(format nil "<SIDREF>kinsystem_motion/kinsystem_motion.kinsystem_inst.inst_~A_axis0</SIDREF>"
                                 joint-name))))
                (eusmodel-joint-description desc))
      ;; joint axis value
      ,@(mapcar #'(lambda (j)
                    (let ((joint-name (cdr (assoc :name j))))
                      `(newparam
                        (@ (sid ,(format nil "libkinscenes.kinScene_libkinscenes.kinScene_inst_kinmodel.~A_axis0_value" joint-name)))
                        ,(format nil "<SIDREF>kinsystem_motion/kinsystem_motion.kinsystem_inst.inst_~A_value</SIDREF>"
                                 joint-name))))
                (eusmodel-joint-description desc))))))

(defun eusmodel-description->collada-library-kinematics-models (name desc)
  `(library_kinematics_models
    (@ (id "libkinmodels"))
    ,(eusmodel-description->collada-kinematics-model name desc)))

(defun eusmodel-description->collada-kinematics-model (name desc)
  (let ((joints-desc (eusmodel-joint-description desc)))
    `(kinematics_model
      (@ (id "kinmodel")
         (name ,(format nil "~A-kinmodel" name))) ;the name of robot...?
      (technique_common
       ,@(joints-description->collada-instance-joints joints-desc)
       ,@(eusmodel-description->collada-links desc)))))

;; returns the name of root link
;; TODO: this function does not work. we need to create a tree
;; of robot models and find the root of the tree.
(defun find-root-link-from-joints-description (joints-description)
  ;; build joint tree using cascaded-coords
  (let ((coords-set nil))
    (dolist (j joints-description)
      (let ((c (make-cascoords :name (cdr (assoc :name j)))))
        (setf (get c :parent-link) (cdr (assoc :parent j)))
        (setf (get c :child-link) (cdr (assoc :child j)))
        (push c coords-set)))
    ;; resolve tree
    (dolist (c coords-set)
      (let ((parent-link (get c :parent-link)))
        (let ((parent-coords
               (find parent-link
                     coords-set
                     :test #'string=
                     :key #'(lambda (c) (get c :child-link)))))
          (unless parent-coords
            ;; this is ROOT!
            (return-from find-root-link-from-joints-description
              parent-link)))))))

(defun find-link-from-links-description (name links-description)
  (find name links-description
        :test #'string= :key #'(lambda (l) (cdr (assoc :name l)))))

(defun eusmodel-description->collada-links (description)
  (let ((joints-description (eusmodel-joint-description description))
        (links-description (eusmodel-link-description description)))
    (let ((root-link-description
           (find-link-from-links-description
            (find-root-link-from-joints-description joints-description)
            links-description)))
      (eusmodel-description->collada-links-tree
       root-link-description links-description joints-description))))

(defun find-joint-from-link-description (target joints)
  (find (cdr (assoc :name target))
        joints
        :test #'string=
        :key #'(lambda (j) (cdr (assoc :child j)))))

(defun find-child-link-descriptions (parent links joints)
  (let ((parented-joints
         (remove-if-not #'(lambda (j) (cdr (assoc :parent j))) joints)))
    (let ((joints-has-parent
           (remove-if-not
            #'(lambda (j)
                (string= (cdr (assoc :parent j))
                         (cdr (assoc :name parent))))
            joints)))
      (let ((child-link-names
             (mapcar #'(lambda (j)
                         (cdr (assoc :child j))) joints-has-parent)))
        (mapcar #'(lambda (n)
                    (find-link-from-links-description n links))
                child-link-names)))))

(defun matrix->collada-rotate-vector (mat)
  "convert a rotation matrix to axis-angle."
  (let ((q (matrix2quaternion mat)))
    (let ((qv (normalize-vector (float-vector (elt q 1) (elt q 2) (elt q 3))))
          (qa (elt q 0)))
      (float-vector (elt qv 0)
                    (elt qv 1)
                    (elt qv 2)
                    (rad2deg (* 2.0 (atan 
                                          (sqrt (+ (expt (elt q 1) 2)
                                                   (expt (elt q 2) 2)
                                                   (expt (elt q 3) 2)))
                                          qa)))))))

(defun eusmodel-description->collada-library-articulated-systems (desc name)
  `(library_articulated_systems
    (articulated_system
     (@ (id "kinsystem")
        (name ,name))
     (kinematics
      (instance_kinematics_model
       ;;(@ (url "#kinmodel")
       (@ (url "#kinmodel")
          (sid "inst_kinmodel"))
       (newparam
        (@ (sid "libarticulated_systems.kinScene_libarticulated_systems.kinScene_inst_kinmodel"))
        "<SIDREF>kinsystem/inst_kinmodel</SIDREF>")
        
       ;; joint axis
       ,@(mapcar #'(lambda (j)
                     (let ((joint-name (cdr (assoc :name j))))
                       `(newparam
                         (@ (sid ,(format nil "libarticulated_systems.kinScene_libarticulated_systems.kinScene_inst_kinmodel.~A_axis0" joint-name)))
                         ,(format nil
                                  "<SIDREF>kinsystem/inst_kinmodel/~A/axis0</SIDREF>~%" joint-name))))
                 (eusmodel-joint-description desc))
       ;; joint axis value
       ,@(mapcar #'(lambda (j)
                     (let ((joint-name (cdr (assoc :name j))))
                       `(newparam
                         (@ (sid ,(format nil "libarticulated_systems.kinScene_libarticulated_systems.kinScene_inst_kinmodel.~A.value" joint-name)))
                         (float "0"))))
                 (eusmodel-joint-description desc)))
      (technique_common
       ,@(mapcar
          #'(lambda (j)
              (let ((joint-name (cdr (assoc :name j))))
                `(axis_info
                  (@ (axis ,(format nil "kinmodel/~A/axis0" joint-name)) ;??
                     (sid ,(format nil "~A_info" joint-name))))))
          (eusmodel-joint-description desc)))))
    (articulated_system
     (@ (id "kinsystem_motion")
	(name "kinsystem_motion"))
     (motion
       (instance_articulated_system
	(@ (url "#kinsystem")
	   (sid "kinsystem_inst"))
        ;; here we bind parameters...
        (newparam
         (@ (sid "kinsystem_motion.kinsystem_inst"))
         "<SIDREF>kinsystem/libarticulated_systems.kinScene_libarticulated_systems.kinScene_inst_kinmodel</SIDREF>")
        ,@(mapcar
           #'(lambda (j)
               (let ((joint-name (cdr (assoc :name j))))
                 `(newparam
                   (@ (sid ,(format nil "kinsystem_motion.kinsystem_inst.inst_~A_axis0" joint-name)))
                   ,(format nil "<SIDREF>kinsystem/libarticulated_systems.kinScene_libarticulated_systems.kinScene_inst_kinmodel.~A_axis0</SIDREF>"
                            joint-name)
                   )))
           (eusmodel-joint-description desc))
        ,@(mapcar
           #'(lambda (j)
               (let ((joint-name (cdr (assoc :name j))))
                 `(newparam
                   (@ (sid ,(format nil "kinsystem_motion.kinsystem_inst.inst_~A_value" joint-name)))
                   ,(format nil "<SIDREF>libarticulated_systems.kinScene_libarticulated_systems.kinScene_inst_kinmodel.~A.value</SIDREF>"
                            joint-name))))
           (eusmodel-joint-description desc)))
       (technique_common
        ,@(mapcar
           #'(lambda (j)
               (let ((joint-name (cdr (assoc :name j))))
                 `(axis_info
                   (@ (axis ,(format nil "kinsystem/~A_info" joint-name))))))
           (eusmodel-joint-description desc))))
     ;; for openrave profile
     ,@(mapcar
        #'(lambda (e)
            (eusmodel-endcoords-description->openrave-manipulator e desc))
        (eusmodel-endcoords-description desc))
     )))

(defun eusmodel-endcoords-description->openrave-manipulator (end-coords description)
  (let ((name (car end-coords))
        (origin-link-name (car (cdr end-coords)))
        (tip-link-name (car (last (cdr end-coords)))))
    `(extra
      (@ (name ,name)
         (type "manipulator"))
      (technique
       (@ (profile "OpenRAVE"))
       (frame_origin
        (@ (link ,(format nil "kinmodel/~A_link" origin-link-name))))
       (frame_tip
        (@ (link ,(format nil "kinmodel/~A_link" tip-link-name))))))))

(defun eusmodel-description->collada-links-tree (target links joints)
  ;; recursive function call!
  (let ((child-links
         (find-child-link-descriptions target links joints)))
    (let ((name (cdr (assoc :name target))))
      ;; output xml of the target and call itself
      `(link
        (@ (sid ,(format nil "~A_link" name))
           (name ,(format nil "~A_link" name)))
        ,@(mapcar
           #'(lambda (l)
               (let ((link-coords (cdr (assoc :origin l)))
                     (j (find-joint-from-link-description l joints)))
                 `((attachment_full
                    (@ (joint ,(format nil
                                       "kinmodel/~A"
                                       (cdr (assoc :name j)))))
                    (translate
                    ,(float-vector->collada-string
                      (send link-coords :worldpos)))
                    (rotate
                     ,(float-vector->collada-string
                       (matrix->collada-rotate-vector
                        (send link-coords :worldrot))))
                    ,(eusmodel-description->collada-links-tree l links
                                                               joints))
                   ))) child-links)))))

(defun joints-description->collada-instance-joints (joints-desc)
  (mapcar #'joint-description->collada-instance-joint joints-desc))

(defun joint-description->collada-instance-joint (joint-desc)
  (let ((name (cdr (assoc :name joint-desc))))
    `(instance_joint
      (@ (url ,(format nil "#~A" name))
         (sid ,name)))))

(defun eusmodel-description->collada-library-joints (description)
  `(library_joints
    (@ (id "libjoints"))
    ,@(joints-description->collada-joints (eusmodel-joint-description description))))

(defun joints-description->collada-joints (joints-description)
  (mapcar #'joint-description->collada-joint joints-description))

(defun collada-joint-id (joint-description)
  (format nil "~A" (cdr (assoc :name joint-description))))


(defun joint-description->collada-joint (joint-description)
  (let ((id (collada-joint-id joint-description))
        (name (cdr (assoc :name joint-description))))
    `(joint
      (@ (id ,id)
         (name ,(format nil "~A" name)))
      ,(cond ((eq (cdr (assoc :type joint-description)) :linear-joint)
              (linear-joint-description->collada-joint joint-description))
             ((eq (cdr (assoc :type joint-description)) :rotational-joint)
              (rotational-joint-description->collada-joint joint-description))
             (t (error "~A is not supported for collada converter"
                       (cdr (assoc :type joint-description))))))))

(defun linear-joint-description->collada-joint (joint-description)
  (let ((limit-description (cdr (assoc :limit joint-description))))
    `(prismatic
      (@ (sid "axis0"))
      (axis ,(float-vector->collada-string
              (cdr (assoc :axis joint-description))))
      (limits
       (min
        ,(format nil "~A" (rad2deg (cdr (assoc :lower limit-description)))))
       (max
        ,(format nil "~A" (rad2deg (cdr (assoc :upper limit-description)))))))))


(defun rotational-joint-description->collada-joint (joint-description)
  (let ((limit-description (cdr (assoc :limit joint-description))))
  `(revolute
    (@ (sid "axis0"))
    (axis ,(float-vector->collada-string
            (cdr (assoc :axis joint-description))))
    (limits
     (min
      ,(format nil "~A" (rad2deg (cdr (assoc :lower limit-description)))))
     (max
      ,(format nil "~A" (rad2deg (cdr (assoc :upper limit-description)))))))))

(defun eusmodel-description->collada-scene (description)
  `(scene
    (instance_visual_scene
     (@ (url "#libvisualscenes.scene")))
    (instance_kinematics_scene
     (@ (url "#libkinscenes.kinScene"))
     (bind_kinematics_model
      (@ (node "root_node"))
      (param
       "libkinscenes.kinScene_libkinscenes.kinScene_inst_kinmodel"))
     ;; bind_joint_axis
      ,@(mapcar
         #'(lambda (j)
             ;; the initial joint angles
             `(bind_joint_axis
               (@ (target ,(format nil "~A.node/~A_axis0"
                                   (cdr (assoc :child j))
                                   (cdr (assoc :name j)))))
               (axis
                (param
                   ,(format
                     nil
                     "libkinscenes.kinScene_libkinscenes.kinScene_inst_kinmodel.~A_axis0"
                     (cdr (assoc :name j)))))
               (value
                (param
                 ,(format nil
                          "libkinscenes.kinScene_libkinscenes.kinScene_inst_kinmodel.~A.value" (cdr (assoc :name j)))))))
         (eusmodel-joint-description description)))))

(defun eusmodel-description->collada-library-geometries (description)
  `(library_geometries
    (@ (id "libgeom"))
    ,@(links-description->collada-geometries (eusmodel-link-description description))))

(defun collada-geometry-id-base (link-descrption)
  (let ((name (cdr (assoc :name link-descrption))))
    (format nil "~A.geometry" name)))

(defun collada-geometry-name-base (link-descrption)
  (let ((name (cdr (assoc :name link-descrption))))
    (format nil "~A_geometry" name)))

(defun links-description->collada-geometries (links-description)
  (mapcar #'link-description->collada-geometry links-description))

(defun mesh-object->collada-mesh (mesh id)
  `(mesh
   (source                            ;list of positions
    (@ (id ,(format nil "~A.positions" id)))
    (float_array
     (@ (id ,(format nil "~A.positions.float-array" id))
        ;;(count ,(* 3 (length (send mesh :vertices)))))
        (count ,(* 3 3 (length (send mesh :faces)))))
     ,(mesh-vertices->collada-string mesh))
    (technique_common
     (accessor
      (@ (source ,(format nil "#~A.positions.float-array" id))
         (count ,(* 3 (length (send mesh :faces))))
         (stride "3"))
      (param (@ (name "X") (type "float")))
      (param (@ (name "Y") (type "float")))
      (param (@ (name "Z") (type "float"))))))
   (source                            ;list of normals
    (@ (id ,(format nil "~A.normals" id)))
    (float_array
     (@ (id ,(format nil "~A.normals.float-array" id))
        (count ,(* 3 (length (send mesh :faces)))))
     ,(mesh-normals->collada-string mesh))
    (technique_common
     (accessor
      (@ (source ,(format nil "#~A.normals.float-array" id))
         (count ,(length (send mesh :faces)))
         (stride "3"))
      (param (@ (name "X") (type "float")))
      (param (@ (name "Y") (type "float")))
      (param (@ (name "Z") (type "float"))))))
   (vertices
    (@ (id ,(format nil "~A.vertices" id)))
    (input
     (@ (semantic "POSITION")
        (source ,(format nil "#~A.positions" id)))))
   (triangles
    (@ (count ,(length (send mesh :faces)))
       (material ,(format nil "~A.material" id)))
    (input
     (@ (offset "0")
        (semantic "VERTEX")
        (source ,(format nil "~A.vertices" id))))
    (input
     (@ (offset "1")
        (semantic "NORMAL")
        (source ,(format nil "~A.normal" id))))
    ;; indices
    ,(mesh->collada-indices mesh)
    )))

(defun link-description->collada-geometry (link-description)
  (let ((id-base (collada-geometry-id-base link-description))
        (name-base (collada-geometry-name-base link-description))
        (meshes (cdr (assoc :mesh link-description))))
    (let ((ids (enum-integer-list (length meshes))))
      (mapcar
       #'(lambda (i m)
           (let ((id (format nil "~A.~A" id-base i))
                 (name (format nil "~A.~A" name-base i)))
             `(geometry
               (@ (id ,id)
                  (name ,name))
               ,(mesh-object->collada-mesh m id))))
       ids meshes))))

(defun mesh->collada-indices (mesh)
  ;; little bit tricky. returns the list of <p> tags as a string!
  (let ((faces (send mesh :faces))
        (ss (make-string-output-stream))
        (vertex-count 0)
        (normal-count 0))
    (format ss "<p>")
    (dotimes (fi (length faces))
      
      (let ((f (elt faces fi)))
        (let ((vertices-num (length (cdr (send f :vertices)))))
          (dotimes (vi vertices-num)
            (format ss "~A " vertex-count) ;vertex index
            (incf vertex-count)           ;increment vertex per vertex
            (format ss "~A " normal-count)) ;normal index
          (incf normal-count)           ;increment normal per faces
          
          )
        (format ss "~%")
        ))
    (format ss "</p>~%")
    (get-output-stream-string ss)))

(defun mesh-vertices->collada-string (mesh)
  (let ((faces (send mesh :faces)))
    ;; vertices = list of float vector
    (let ((ss (make-string-output-stream)))
      (dolist (f faces)
        (let ((vertices (cdr (send f :vertices))))
          (dolist (v vertices)
            (dotimes (i 3)
              (format ss "~A " (elt v i)))
            (format ss "~%"))))
      (get-output-stream-string ss))))

(defun mesh-normals->collada-string (mesh)
  (let ((faces (send mesh :faces)))
    (let ((ss (make-string-output-stream)))
      (dolist (f faces)
        (let ((normal (send f :normal)))
          (dotimes (i 3)
            (format ss "~A " (elt normal i)))
          (format ss "~%")))
      (get-output-stream-string ss))))

(defun float-vector->collada-string (v)
  (let ((ss (make-string-output-stream)))
    (dotimes (i (length v))
      (format ss "~A " (elt v i)))
    (format ss "~%")
    (get-output-stream-string ss)))

;; util
(defun enum-integer-list (n)
  (let ((ids nil))
    (dotimes (i n)
      (push i ids))
    (reverse ids)))

