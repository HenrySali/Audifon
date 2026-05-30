/**
 * Clasificador de Entorno con Machine Learning
 * 
 * Mejora el clasificador de entorno basado en reglas (environment_classifier.cpp)
 * con un modelo que aprende de los patrones del usuario.
 * 
 * Funcionalidades:
 * - Entrena con historial de clasificaciones del usuario
 * - Predice cambios de perfil antes de que ocurran
 * - Personaliza umbrales de NR según entorno frecuente
 * - Exporta modelo ligero para inferencia en el dispositivo
 * 
 * Uso:
 *   const { EnvironmentML } = require('./environment-ml');
 *   const ml = new EnvironmentML();
 *   ml.train(historyData);
 *   const prediction = ml.predict(currentFeatures);
 */

class EnvironmentML {
    constructor() {
        // Clases de entorno
        this.classes = ['quiet', 'conversation', 'noisy', 'music', 'outdoor'];

        // Modelo: pesos por feature por clase (perceptrón multicapa simple)
        this.weights = null;
        this.biases = null;
        this.trained = false;

        // Features esperadas del audio
        this.featureNames = [
            'rmsLevel',         // Nivel RMS en dB
            'spectralCentroid', // Centroide espectral (Hz)
            'spectralFlux',     // Cambio espectral entre frames
            'zeroCrossRate',    // Tasa de cruces por cero
            'lowBandEnergy',    // Energía < 500 Hz (ratio)
            'midBandEnergy',    // Energía 500-2000 Hz (ratio)
            'highBandEnergy',   // Energía > 2000 Hz (ratio)
            'modulationRate',   // Tasa de modulación de amplitud
            'snrEstimate',      // SNR estimado
            'peakiness'         // Relación pico/RMS (crest factor)
        ];

        // Historial de predicciones para aprendizaje continuo
        this.history = [];
        this.maxHistory = 1000;

        // Inicializar con pesos por defecto (basados en reglas conocidas)
        this._initDefaultWeights();
    }

    /**
     * Inicializa pesos por defecto basados en conocimiento del dominio
     */
    _initDefaultWeights() {
        // Pesos iniciales que replican el clasificador basado en reglas
        // [rms, centroid, flux, zcr, low, mid, high, modRate, snr, peak]
        this.weights = {
            quiet:        [-0.8, -0.3, -0.5, -0.2, 0.3, -0.1, -0.2, -0.5, 0.5, -0.3],
            conversation: [0.2, 0.3, 0.2, 0.3, -0.1, 0.6, 0.2, 0.5, 0.3, 0.1],
            noisy:        [0.6, 0.1, 0.5, 0.4, 0.3, 0.2, 0.3, 0.1, -0.6, 0.2],
            music:        [0.3, 0.5, 0.3, -0.1, 0.2, 0.3, 0.4, 0.3, 0.2, 0.4],
            outdoor:      [0.4, -0.2, 0.4, 0.2, 0.4, 0.1, -0.1, 0.2, -0.2, 0.1]
        };

        this.biases = {
            quiet: 0.5,
            conversation: 0.3,
            noisy: -0.2,
            music: -0.3,
            outdoor: -0.1
        };
    }

    /**
     * Predice la clase de entorno
     * @param {Object} features - Features extraídas del audio actual
     * @returns {Object} Predicción con confianza
     */
    predict(features) {
        const featureVector = this._normalizeFeatures(features);
        const scores = {};

        for (const cls of this.classes) {
            let score = this.biases[cls];
            for (let i = 0; i < featureVector.length; i++) {
                score += this.weights[cls][i] * featureVector[i];
            }
            scores[cls] = score;
        }

        // Softmax para probabilidades
        const probs = this._softmax(scores);

        // Clase ganadora
        const predicted = Object.entries(probs)
            .sort((a, b) => b[1] - a[1])[0];

        return {
            class: predicted[0],
            confidence: predicted[1],
            probabilities: probs,
            features: features
        };
    }

    /**
     * Entrena el modelo con datos históricos
     * @param {Array} data - [{ features: {...}, label: 'quiet'|'conversation'|... }]
     * @param {Object} options - { epochs, learningRate }
     */
    train(data, options = {}) {
        const { epochs = 50, learningRate = 0.01 } = options;

        if (data.length < 10) {
            console.warn('⚠ Datos insuficientes para entrenamiento (mínimo 10 muestras)');
            return { success: false, reason: 'insufficient_data' };
        }

        let totalLoss = 0;

        for (let epoch = 0; epoch < epochs; epoch++) {
            totalLoss = 0;

            // Shuffle datos
            const shuffled = [...data].sort(() => Math.random() - 0.5);

            for (const sample of shuffled) {
                const featureVector = this._normalizeFeatures(sample.features);
                const target = sample.label;

                // Forward pass
                const scores = {};
                for (const cls of this.classes) {
                    let score = this.biases[cls];
                    for (let i = 0; i < featureVector.length; i++) {
                        score += this.weights[cls][i] * featureVector[i];
                    }
                    scores[cls] = score;
                }

                const probs = this._softmax(scores);

                // Calcular loss (cross-entropy)
                totalLoss -= Math.log(Math.max(probs[target], 1e-10));

                // Backward pass (gradient descent)
                for (const cls of this.classes) {
                    const error = probs[cls] - (cls === target ? 1 : 0);
                    for (let i = 0; i < featureVector.length; i++) {
                        this.weights[cls][i] -= learningRate * error * featureVector[i];
                    }
                    this.biases[cls] -= learningRate * error;
                }
            }

            totalLoss /= data.length;
        }

        this.trained = true;
        return {
            success: true,
            finalLoss: totalLoss,
            samples: data.length,
            epochs: epochs
        };
    }

    /**
     * Registra una corrección del usuario (aprendizaje continuo)
     * @param {Object} features - Features del momento
     * @param {string} correctLabel - Clase correcta según el usuario
     */
    addCorrection(features, correctLabel) {
        this.history.push({ features, label: correctLabel, timestamp: Date.now() });

        if (this.history.length > this.maxHistory) {
            this.history = this.history.slice(-this.maxHistory);
        }

        // Re-entrenar con las últimas correcciones (online learning)
        if (this.history.length >= 10 && this.history.length % 5 === 0) {
            this.train(this.history.slice(-50), { epochs: 10, learningRate: 0.005 });
        }
    }

    /**
     * Genera configuración de NR personalizada por entorno
     * @param {string} environment - Clase de entorno
     * @returns {Object} Parámetros de NR recomendados
     */
    getRecommendedNR(environment) {
        const nrConfigs = {
            quiet: { aggressiveness: 0.2, gainFloor: 0.3, enabled: true },
            conversation: { aggressiveness: 0.4, gainFloor: 0.2, enabled: true },
            noisy: { aggressiveness: 0.8, gainFloor: 0.15, enabled: true },
            music: { aggressiveness: 0.1, gainFloor: 0.5, enabled: false },
            outdoor: { aggressiveness: 0.6, gainFloor: 0.18, enabled: true }
        };
        return nrConfigs[environment] || nrConfigs.conversation;
    }

    /**
     * Exporta modelo para uso en firmware/app
     * @returns {Object} Modelo serializado (pesos + biases)
     */
    exportModel() {
        return {
            version: '1.0.0',
            classes: this.classes,
            featureNames: this.featureNames,
            weights: this.weights,
            biases: this.biases,
            trained: this.trained,
            historySize: this.history.length,
            exportedAt: new Date().toISOString()
        };
    }

    /**
     * Importa modelo previamente exportado
     */
    importModel(model) {
        if (model.weights && model.biases) {
            this.weights = model.weights;
            this.biases = model.biases;
            this.trained = model.trained || true;
            return true;
        }
        return false;
    }

    /**
     * Normaliza features a rango [-1, 1]
     */
    _normalizeFeatures(features) {
        const ranges = {
            rmsLevel: { min: -80, max: 0 },
            spectralCentroid: { min: 100, max: 8000 },
            spectralFlux: { min: 0, max: 1 },
            zeroCrossRate: { min: 0, max: 0.5 },
            lowBandEnergy: { min: 0, max: 1 },
            midBandEnergy: { min: 0, max: 1 },
            highBandEnergy: { min: 0, max: 1 },
            modulationRate: { min: 0, max: 20 },
            snrEstimate: { min: -10, max: 40 },
            peakiness: { min: 1, max: 20 }
        };

        return this.featureNames.map(name => {
            const val = features[name] || 0;
            const range = ranges[name] || { min: 0, max: 1 };
            return 2 * (val - range.min) / (range.max - range.min) - 1;
        });
    }

    /**
     * Softmax para convertir scores a probabilidades
     */
    _softmax(scores) {
        const values = Object.values(scores);
        const maxVal = Math.max(...values);
        const exps = {};
        let sumExp = 0;

        for (const [cls, score] of Object.entries(scores)) {
            exps[cls] = Math.exp(score - maxVal);
            sumExp += exps[cls];
        }

        const probs = {};
        for (const cls of this.classes) {
            probs[cls] = exps[cls] / sumExp;
        }
        return probs;
    }
}

module.exports = { EnvironmentML };
