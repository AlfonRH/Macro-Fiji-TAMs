// Macro de Fiji para la cuantificación automatizada de macrófagos (TAMs)
// Calcula el tamaño celular y la fluorescencia neta por célula individual

var dirSalida, modeloNucleos; 

macro "Analisis_TAMs_Fluorescencia_Neta" {
    dirEntrada = getDirectory("Seleccione la carpeta con las imágenes (.oif):");
    dirSalida = getDirectory("Seleccione la carpeta para guardar los resultados:");
    
    // Cargar el modelo de inteligencia artificial entrenado para detectar núcleos
    modeloNucleos = File.openDialog("Seleccione el modelo Weka (.model):");

    setBatchMode(true); 
    buscarEnCarpetas(dirEntrada);
    setBatchMode(false);
    
    showMessage("Proceso Finalizado", "Análisis completado. Archivos CSV e imágenes de control guardados.");
}

// Función para buscar imágenes dentro de todas las subcarpetas del experimento
function buscarEnCarpetas(carpetaActual) {
    lista = getFileList(carpetaActual);
    for (i = 0; i < lista.length; i++) {
        if (File.isDirectory(carpetaActual + lista[i])) {
            // Ignorar las carpetas internas que crea el microscopio Olympus
            if (!endsWith(lista[i], ".oif.files/") && !endsWith(lista[i], ".OIF.files/")) {
                buscarEnCarpetas(carpetaActual + lista[i]);
            }
        } 
        else if (endsWith(lista[i], ".oif") || endsWith(lista[i], ".OIF")) {
            procesarImagen(carpetaActual, lista[i]);
        }
    }
}

// Función principal para procesar cada imagen individual
function procesarImagen(ruta, nombreArchivo) {
    // 1. Abrir la imagen y hacer una proyección Z sumando las intensidades
    run("Bio-Formats Importer", "open=[" + ruta + nombreArchivo + "] autoscale color_mode=Default view=Hyperstack stack_order=XYCZT windowless=true");
    tituloOriginal = getTitle();
    run("Z Project...", "projection=[Sum Slices]");
    tituloSuma = getTitle();
    close(tituloOriginal); 

    // 2. Separar los canales (DAPI, Faloidina y CD206)
    run("Split Channels");
    selectWindow("C1-" + tituloSuma); rename("Ori_DAPI");
    selectWindow("C2-" + tituloSuma); rename("Ori_PHAL");
    selectWindow("C3-" + tituloSuma); rename("Ori_CD206");

    // FASE A: Detectar el cuerpo celular usando el canal de Faloidina
    // Se aplica un suavizado y un umbral automático para delimitar las células
    selectWindow("Ori_PHAL");
    run("Duplicate...", "title=Copia_PHAL"); 
    run("Gaussian Blur...", "sigma=3"); 
    setAutoThreshold("Huang dark"); 
    setOption("BlackBackground", true);
    run("Convert to Mask");
    run("Close-");     
    run("Fill Holes"); 
    rename("Mascara_Celulas");
    
    roiManager("reset");
    run("Analyze Particles...", "size=50-Infinity show=Nothing add");

    // FASE B: Detectar los núcleos usando el canal DAPI y el modelo Weka
    // Se utiliza la herramienta Watershed para separar los núcleos que estén tocándose
    selectWindow("Ori_DAPI");
    run("Duplicate...", "title=Copia_DAPI"); 
    run("Trainable Weka Segmentation");
    call("trainableSegmentation.Weka_Segmentation.loadClassifier", modeloNucleos);
    call("trainableSegmentation.Weka_Segmentation.getResult");
    
    setOption("BlackBackground", true);
    run("Make Binary");
    run("Fill Holes"); 
    run("Watershed"); 
    rename("Mascara_Nucleos");

    // FASE C: Filtrar las células válidas
    // Se eliminan agrupaciones o restos, dejando solo células con 1 núcleo exacto
    run("Clear Results");
    totalCelulas = roiManager("count");

    // Se revisan las células de atrás hacia adelante para poder borrarlas sin errores
    for (c = totalCelulas - 1; c >= 0; c--) {
        selectWindow("Mascara_Nucleos");
        roiManager("select", c);
        run("Analyze Particles...", "size=20-Infinity clear");
        
        if (nResults != 1) {
            roiManager("select", c); 
            roiManager("delete");    
        }
    }

    // FASE D: Medir parámetros y guardar en Excel
    numCelulasFinales = roiManager("count");
    
    if (numCelulasFinales > 0) {
        
        // Medir el ruido de fondo (áreas de la imagen donde no hay células)
        selectWindow("Mascara_Celulas");
        run("Create Selection");
        run("Make Inverse"); 
        
        selectWindow("Ori_CD206"); 
        run("Clear Results");
        run("Set Measurements...", "mean decimal=2"); 
        run("Measure");
        meanFondo = getResult("Mean", 0); 
        run("Select None"); 
        
        // Medir el tamaño y la fluorescencia de cada célula en el canal de interés
        run("Clear Results"); 
        run("Set Measurements...", "area mean perimeter feret's shape redirect=[Ori_CD206] decimal=2");
        roiManager("select", Array.getSequence(numCelulasFinales));
        roiManager("Measure");
        
        rutaSinBarra = substring(ruta, 0, lengthOf(ruta)-1);
        nombreCarpeta = File.getName(rutaSinBarra);
        archivoExcel = dirSalida + nombreCarpeta + "_Resultados.csv";
        
        // Crear la cabecera del archivo si es la primera imagen de la carpeta
        if (!File.exists(archivoExcel)) {
            File.append("Imagen;Numero_Celula;Area;Mean_CD206;Mean_Fondo;Mean_Neto;Perimetro;Feret;Roundness", archivoExcel);
        }
        
        fondoTraduccion = replace(""+meanFondo, ".", ",");

        for (r = 0; r < nResults; r++) {
            area = getResult("Area", r);
            mean = getResult("Mean", r);
            
            // Calcular la fluorescencia neta restando el ruido de fondo local
            neto = mean - meanFondo;
            
            // Cambiar los puntos por comas para que el Excel en español lo lea como número
            area_trad  = replace(""+area, ".", ",");
            mean_trad  = replace(""+mean, ".", ",");
            neto_trad  = replace(""+neto, ".", ","); 
            perim_trad = replace(""+getResult("Perim.", r), ".", ",");  
            feret_trad = replace(""+getResult("Feret", r), ".", ",");  
            round_trad = replace(""+getResult("Round", r), ".", ",");  
            
            linea = nombreArchivo + ";" + (r+1) + ";" + area_trad + ";" + mean_trad + ";" + fondoTraduccion + ";" + neto_trad + ";" + perim_trad + ";" + feret_trad + ";" + round_trad;
            File.append(linea, archivoExcel);
        }

        // FASE E: Guardar una foto de control para comprobar que ha medido bien
        // Dibuja el contorno y el número de cada célula analizada
        selectWindow("Ori_PHAL"); 
        run("Enhance Contrast", "saturated=0.35 normalize"); 
        run("RGB Color"); 
        
        run("Labels...", "font=18 show draw_labels bold");
        roiManager("Show All with labels"); 
        roiManager("Set Color", "yellow"); 
        roiManager("Set Line Width", 2);
        
        run("Flatten"); 
        
        nombreJPG = replace(nombreArchivo, ".oif", "_Control.jpg");
        nombreJPG = replace(nombreJPG, ".OIF", "_Control.jpg");
        saveAs("Jpeg", dirSalida + nombreCarpeta + "_" + nombreJPG);
    }

    // Limpiar la memoria antes de pasar a la siguiente imagen
    run("Close All");
    roiManager("reset");
    run("Clear Results");
    call("java.lang.System.gc");
}
